part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for auditing memory usage and finding object retaining paths.
extension MemoryHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleAuditClassMemoryLeak(
      CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final className = req.arguments!['class_name'] as String;

    try {
      stderr.writeln('[mcp:audit_memory] Auditing class: $className');
      // Fetch classes to find class ID
      final classList = await _vmService!.getClassList(_isolateId!);
      final classRef = classList.classes!.firstWhere(
        (c) => c.name == className,
        orElse: () => throw Exception('Class $className not found.'),
      );

      // Fetch active instances in heap
      final instancesResponse =
          await _vmService!.getInstances(_isolateId!, classRef.id!, 100);
      final instances = instancesResponse.instances ?? [];

      final reports = <Map<String, dynamic>>[];
      final mdBuffer = StringBuffer();

      for (final instanceRef in instances) {
        final instanceId = instanceRef.id!;

        final evalResult = await _vmService!.evaluate(
          _isolateId!,
          instanceId,
          'this.mounted',
        );

        final isMounted =
            evalResult is InstanceRef && evalResult.valueAsString == 'true';
        if (!isMounted) {
          final retainingPath =
              await _vmService!.getRetainingPath(_isolateId!, instanceId, 15);
          final pathElements = <String>[];

          for (final element in retainingPath.elements ?? []) {
            final val = element.value;
            if (val is InstanceRef) {
              pathElements.add('${val.classRef?.name} (${val.id})');
            } else {
              pathElements.add(val.toString());
            }
          }

          reports.add({
            'instance_id': instanceId,
            'mounted': false,
            'retaining_path': pathElements,
          });
        }
      }

      if (reports.isEmpty) {
        mdBuffer.writeln(
            'No memory leaks detected for class `$className`. All heap instances are active.');
      } else {
        mdBuffer.writeln(
            'Warning: Detected ${reports.length} leaked instances for `$className`!');
        for (var i = 0; i < reports.length; i++) {
          mdBuffer.writeln(
              '\n#### Leaked Instance #${i + 1} (${reports[i]['instance_id']})');
          mdBuffer.writeln(
              '- Disposed State: mounted == false but retained in memory.');
          mdBuffer.writeln('- Retention Path:');
          for (final node in reports[i]['retaining_path'] as List<String>) {
            mdBuffer.writeln('  - $node');
          }
        }
      }

      return _serializeDualFormat(
        title: '### Memory Leak Audit: $className',
        markdownBody: mdBuffer.toString(),
        structuredData: {
          'class_name': className,
          'total_instances': instances.length,
          'leaked_count': reports.length,
          'leaks': reports,
        },
      );
    } catch (e) {
      stderr.writeln('[mcp:audit_memory] ERROR: $e');
      return CallToolResult(
          content: [TextContent(text: 'Memory audit failed: $e')],
          isError: true);
    }
  }

  Future<CallToolResult> _handleDiffHeapAllocations(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final duration = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 3;
    final expression = req.arguments?['expression'] as String?;
    final forceGc = req.arguments?['force_gc'] as bool? ?? true;

    stderr.writeln(
        '[mcp:diff_heap] Starting heap profiling (duration=${duration}s, forceGc=$forceGc)');

    try {
      // First snapshot
      final baselineProfile =
          await _vmService!.getAllocationProfile(_isolateId!, gc: forceGc);
      final baselineStats = <String, ClassHeapStats>{};
      for (final member in baselineProfile.members ?? []) {
        if (member.classRef?.name != null) {
          baselineStats[member.classRef!.name!] = member;
        }
      }

      // Action / delay
      if (expression != null && expression.isNotEmpty) {
        stderr.writeln(
            '[mcp:diff_heap] Evaluating action expression: $expression');
        try {
          final libraryId = await _getEvaluationLibraryId();
          await _vmService!.evaluate(_isolateId!, libraryId, expression);
        } catch (e) {
          stderr.writeln('[mcp:diff_heap] Action evaluation failed: $e');
        }
      }

      stderr.writeln('[mcp:diff_heap] Sampling memory for ${duration}s...');
      await Future.delayed(Duration(seconds: duration));

      // Second snapshot (do not force GC here so we see temporary allocations)
      final currentProfile =
          await _vmService!.getAllocationProfile(_isolateId!, gc: false);
      final deltas = <Map<String, dynamic>>[];

      for (final member in currentProfile.members ?? []) {
        final className = member.classRef?.name;
        if (className == null) continue;

        final baseline = baselineStats[className];
        final baselineInstances = baseline?.instancesCurrent ?? 0;
        final baselineBytes = baseline?.bytesCurrent ?? 0;

        final currentInstances = member.instancesCurrent ?? 0;
        final currentBytes = member.bytesCurrent ?? 0;

        final instanceDelta = currentInstances - baselineInstances;
        final bytesDelta = currentBytes - baselineBytes;

        if (instanceDelta != 0 || bytesDelta != 0) {
          deltas.add({
            'class': className,
            'instances_before': baselineInstances,
            'instances_after': currentInstances,
            'instances_delta': instanceDelta,
            'bytes_before': baselineBytes,
            'bytes_after': currentBytes,
            'bytes_delta': bytesDelta,
          });
        }
      }

      // Sort by absolute instance delta descending
      deltas.sort((a, b) {
        final cmp = (b['instances_delta'] as int)
            .abs()
            .compareTo((a['instances_delta'] as int).abs());
        if (cmp != 0) return cmp;
        return (b['bytes_delta'] as int)
            .abs()
            .compareTo((a['bytes_delta'] as int).abs());
      });

      final md = StringBuffer('### Memory Allocations Delta\n\n');
      if (deltas.isEmpty) {
        md.writeln(
            'No heap allocation changes recorded during the profiling window.');
      } else {
        md.writeln(
            '| Class | Instances Delta | Bytes Delta | Before (Count / Size) | After (Count / Size) |');
        md.writeln('| :--- | :--- | :--- | :--- | :--- |');
        for (final d in deltas.take(20)) {
          final instDeltaStr = d['instances_delta'] > 0
              ? '+${d['instances_delta']}'
              : '${d['instances_delta']}';
          final byteDeltaStr = d['bytes_delta'] > 0
              ? '+${d['bytes_delta']} B'
              : '${d['bytes_delta']} B';
          md.writeln(
            '| **${d['class']}** | $instDeltaStr | $byteDeltaStr | '
            '${d['instances_before']} / ${d['bytes_before']} B | '
            '${d['instances_after']} / ${d['bytes_after']} B |',
          );
        }
        if (deltas.length > 20) {
          md.writeln('\n_...and ${deltas.length - 20} more classes._');
        }
      }

      return _serializeDualFormat(
        title: '### Allocation Snapshot Difference',
        markdownBody: md.toString(),
        structuredData: {
          'duration_seconds': duration,
          'expression_run': expression,
          'force_gc': forceGc,
          'deltas': deltas,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:diff_heap] ERROR: $e');
      stderr.writeln('[mcp:diff_heap] STACKTRACE: $st');
      return CallToolResult(
          content: [TextContent(text: 'Heap diff failed: $e')], isError: true);
    }
  }

  Future<CallToolResult> _handleGetObjectReferrers(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final objectId = req.arguments!['object_id'] as String;
    final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 15;
    stderr.writeln(
        '[mcp:get_referrers] Checking referrers for object_id=$objectId, limit=$limit');

    try {
      final retainingPath =
          await _vmService!.getRetainingPath(_isolateId!, objectId, limit);
      final pathElements = <String>[];

      for (final element in retainingPath.elements ?? []) {
        final val = element.value;
        if (val is InstanceRef) {
          pathElements.add('${val.classRef?.name} (${val.id})');
        } else {
          pathElements.add(val.toString());
        }
      }

      final md = StringBuffer('### Retaining Path for Object: `$objectId`\n\n');
      if (pathElements.isEmpty) {
        md.writeln(
            'No retaining path returned. The object might have been garbage collected or is a root.');
      } else {
        md.writeln(
            'The following references are keeping this object alive in the heap:');
        md.writeln();
        for (var i = 0; i < pathElements.length; i++) {
          md.writeln('${i + 1}. **${pathElements[i]}**');
        }
      }

      return _serializeDualFormat(
        title: '### Retaining Path / Leak Trace Report',
        markdownBody: md.toString(),
        structuredData: {
          'object_id': objectId,
          'path_length': pathElements.length,
          'retaining_path': pathElements,
          'raw_response': retainingPath.json,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:get_referrers] ERROR: $e');
      stderr.writeln('[mcp:get_referrers] STACKTRACE: $st');
      return CallToolResult(
          content: [TextContent(text: 'Failed to retrieve retaining path: $e')],
          isError: true);
    }
  }
}
