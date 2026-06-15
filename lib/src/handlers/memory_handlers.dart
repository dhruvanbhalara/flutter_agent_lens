part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for auditing memory usage and finding object retaining paths.
extension MemoryHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleAuditClassMemoryLeak(
      CallToolRequest req) async {
    final className = req.arguments!['class_name'] as String;

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
      title: 'Memory Leak Audit: $className',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'class_name': className,
        'total_instances': instances.length,
        'instances': instances.map((i) => i.id).whereType<String>().toList(),
        'leaked_count': reports.length,
        'leaks': reports,
      },
      format: req.arguments?['format'] as String?,
    );
  }

  Future<CallToolResult> _handleDiffHeapAllocations(CallToolRequest req) async {
    final duration = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 3;
    final expression = req.arguments?['expression'] as String?;
    final forceGc = req.arguments?['force_gc'] as bool? ?? true;

    stderr.writeln(
        '[mcp:diff_heap] Starting heap profiling (duration=${duration}s, forceGc=$forceGc)');

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
      stderr
          .writeln('[mcp:diff_heap] Evaluating action expression: $expression');
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

    _sortDeltas(deltas, 'instances_delta', 'bytes_delta');

    final md = StringBuffer('Memory Allocations Delta\n\n')
      ..write(_formatAllocationDiffTable(deltas, limit: 20));

    return _serializeDualFormat(
      title: 'Allocation Snapshot Difference',
      markdownBody: md.toString(),
      structuredData: {
        'duration_seconds': duration,
        'expression_run': expression,
        'force_gc': forceGc,
        'deltas': deltas.take(50).toList(),
      },
      format: req.arguments?['format'] as String?,
    );
  }

  Future<CallToolResult> _handleGetObjectReferrers(CallToolRequest req) async {
    final objectId = req.arguments!['object_id'] as String;
    final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 15;
    final includeRawResponse = req.arguments?['includeRawResponse'] as bool? ?? false;
    stderr.writeln(
        '[mcp:get_referrers] Checking referrers for object_id=$objectId, limit=$limit');

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

    final md = StringBuffer('Retaining Path for Object: $objectId\n\n');
    if (pathElements.isEmpty) {
      md.writeln(
          'No retaining path returned. The object might have been garbage collected or is a root.');
    } else {
      md.writeln(
          'The following references are keeping this object alive in the heap:');
      md.writeln();
      for (var i = 0; i < pathElements.length; i++) {
        md.writeln('${i + 1}. ${pathElements[i]}');
      }
    }

    return _serializeDualFormat(
      title: 'Retaining Path / Leak Trace Report',
      markdownBody: md.toString(),
      structuredData: {
        'object_id': objectId,
        'path_length': pathElements.length,
        'retaining_path': pathElements,
        if (includeRawResponse) 'raw_response': retainingPath.json,
      },
      format: req.arguments?['format'] as String?,
    );
  }

  Future<CallToolResult> _handleSaveSnapshot(CallToolRequest req) async {
    final name = req.arguments!['name'] as String;
    final forceGc = (req.arguments?['forceGC'] as bool?) ?? true;

    final snapshot = await _takeSnapshot(name, forceGc);
    _memorySnapshots[name] = snapshot;

    final lines = [
      'Snapshot "$name" saved.',
      '',
      'Heap: ${_formatBytes(snapshot.heapUsage)} / ${_formatBytes(snapshot.heapCapacity)}',
      'Classes tracked: ${snapshot.topClasses.length}',
      'Time: ${DateTime.fromMillisecondsSinceEpoch(snapshot.timestamp).toLocal().toString().split(" ").last.split(".").first}',
      '',
      'Saved snapshots: ${_memorySnapshots.keys.join(", ")}',
    ];

    return CallToolResult(
      content: [TextContent(text: lines.join('\n'))],
    );
  }

  Future<CallToolResult> _handleCompareSnapshots(CallToolRequest req) async {
    final before = req.arguments!['before'] as String;
    final after = req.arguments!['after'] as String;

    final snap1 = _memorySnapshots[before];
    final snap2 = _memorySnapshots[after];

    if (snap1 == null) {
      final available = _memorySnapshots.keys.isEmpty
          ? 'none'
          : _memorySnapshots.keys.join(', ');
      return CallToolResult(
        content: [
          TextContent(
              text: 'Snapshot "$before" not found. Available: $available')
        ],
        isError: true,
      );
    }

    if (snap2 == null) {
      final available = _memorySnapshots.keys.isEmpty
          ? 'none'
          : _memorySnapshots.keys.join(', ');
      return CallToolResult(
        content: [
          TextContent(
              text: 'Snapshot "$after" not found. Available: $available')
        ],
        isError: true,
      );
    }

    final heapDiff = snap2.heapUsage - snap1.heapUsage;
    final capacityDiff = snap2.heapCapacity - snap1.heapCapacity;

    final beforeMap = {for (final c in snap1.topClasses) c.name: c};
    final afterMap = {for (final c in snap2.topClasses) c.name: c};

    final allClassNames = <String>{
      ...beforeMap.keys,
      ...afterMap.keys,
    };

    final diffs = <Map<String, dynamic>>[];

    for (final name in allClassNames) {
      final b = beforeMap[name];
      final a = afterMap[name];
      final bBytes = b?.bytes ?? 0;
      final aBytes = a?.bytes ?? 0;
      final bInstances = b?.instances ?? 0;
      final aInstances = a?.instances ?? 0;

      diffs.add({
        'name': name,
        'bytesBefore': bBytes,
        'bytesAfter': aBytes,
        'bytesDiff': aBytes - bBytes,
        'instancesBefore': bInstances,
        'instancesAfter': aInstances,
        'instancesDiff': aInstances - bInstances,
      });
    }

    final grew = diffs.where((d) => (d['bytesDiff'] as int) > 0).toList();
    _sortDeltas(grew, 'instancesDiff', 'bytesDiff');

    final shrank = diffs.where((d) => (d['bytesDiff'] as int) < 0).toList();
    _sortDeltas(shrank, 'instancesDiff', 'bytesDiff');

    final heapIcon = heapDiff <= 0
        ? '[OK]'
        : heapDiff > 10000000
            ? '[WARNING]'
            : '[INFO]';
    final timeDiffS =
        ((snap2.timestamp - snap1.timestamp) / 1000).toStringAsFixed(1);

    final md = StringBuffer();
    md.writeln('SNAPSHOT COMPARISON: "$before" -> "$after"');
    md.writeln();
    md.writeln('HEAP OVERVIEW');
    md.writeln('$heapIcon Heap usage: ${_formatBytes(snap1.heapUsage)} -> ${_formatBytes(snap2.heapUsage)} (${heapDiff <= 0 ? "" : "+"}${_formatBytes(heapDiff)}, ${_pctChange(snap1.heapUsage, snap2.heapUsage)})');
    md.writeln('Capacity: ${_formatBytes(snap1.heapCapacity)} -> ${_formatBytes(snap2.heapCapacity)} (${capacityDiff <= 0 ? "" : "+"}${_formatBytes(capacityDiff)})');
    md.writeln('Time between snapshots: ${timeDiffS}s');

    if (grew.isNotEmpty) {
      md.writeln();
      md.writeln('GREW (top 10)');
      for (final d in grew.take(10)) {
        final instDiffVal = d['instancesDiff'] as int;
        final instDiff = instDiffVal > 0 ? '+$instDiffVal' : '$instDiffVal';
        md.writeln('+${_formatBytes(d['bytesDiff'] as int)} | $instDiff inst | ${d['name']}');
      }
    }

    if (shrank.isNotEmpty) {
      md.writeln();
      md.writeln('SHRANK (top 10)');
      for (final d in shrank.take(10)) {
        final instDiffVal = d['instancesDiff'] as int;
        final instDiff = instDiffVal > 0 ? '+$instDiffVal' : '$instDiffVal';
        md.writeln('-${_formatBytes((d['bytesDiff'] as int).abs())} | $instDiff inst | ${d['name']}');
      }
    }

    md.writeln();
    md.writeln('VERDICT');
    if (heapDiff < -1000000) {
      md.writeln('Memory improved by ${_formatBytes(heapDiff.abs())} (${_pctChange(snap1.heapUsage, snap2.heapUsage)}).');
    } else if (heapDiff > 1000000) {
      md.writeln('Warning: Memory increased by ${_formatBytes(heapDiff)} (${_pctChange(snap1.heapUsage, snap2.heapUsage)}). Check the classes that grew above.');
    } else {
      md.writeln('No significant change in memory usage between snapshots.');
    }

    return _serializeDualFormat(
      title: 'Snapshot Comparison: "$before" -> "$after"',
      markdownBody: md.toString(),
      structuredData: {
        'before': before,
        'after': after,
        'heap_diff_bytes': heapDiff,
        'heap_pct_change': _pctChange(snap1.heapUsage, snap2.heapUsage),
        'time_diff_seconds': double.tryParse(timeDiffS) ?? 0.0,
        'grew': grew.take(10).toList(),
        'shrank': shrank.take(10).toList(),
      },
      format: req.arguments?['format'] as String?,
    );
  }

  Future<CallToolResult> _handleListSnapshots(CallToolRequest req) async {
    if (_memorySnapshots.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'No snapshots saved yet. Use `save_snapshot` to create one.')
        ],
      );
    }

    final lines = ['Saved snapshots:', ''];
    _memorySnapshots.forEach((name, snap) {
      final timeStr = DateTime.fromMillisecondsSinceEpoch(snap.timestamp)
          .toLocal()
          .toString()
          .split(' ')
          .last
          .split('.')
          .first;
      lines.add('- "$name" - ${_formatBytes(snap.heapUsage)} heap, $timeStr');
    });

    return CallToolResult(
      content: [TextContent(text: lines.join('\n'))],
    );
  }

  Future<_MemorySnapshot> _takeSnapshot(String name, bool gc) async {
    final profile = await _vmService!.getAllocationProfile(_isolateId!, gc: gc);
    final heapUsage = profile.memoryUsage?.heapUsage ?? 0;
    final heapCapacity = profile.memoryUsage?.heapCapacity ?? 0;
    final externalUsage = profile.memoryUsage?.externalUsage ?? 0;

    final members = profile.members ?? [];
    final validMembers =
        members.where((m) => m.classRef?.name != null).toList();

    validMembers
        .sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));
    final sorted =
        validMembers.where((m) => (m.bytesCurrent ?? 0) > 0).take(50).toList();

    final topClasses = sorted
        .map((m) => _ClassAllocation(
              name: m.classRef!.name!,
              bytes: m.bytesCurrent ?? 0,
              instances: m.instancesCurrent ?? 0,
            ))
        .toList();

    return _MemorySnapshot(
      name: name,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      heapUsage: heapUsage,
      heapCapacity: heapCapacity,
      externalUsage: externalUsage,
      topClasses: topClasses,
    );
  }

  String _pctChange(int before, int after) {
    if (before == 0) return after > 0 ? '+inf%' : '0%';
    final pct = ((after - before) / before) * 100;
    final sign = pct > 0 ? '+' : '';
    return '$sign${pct.toStringAsFixed(1)}%';
  }

  Future<CallToolResult> _handleGetMemorySnapshot(CallToolRequest req) async {
    final forceGc = (req.arguments?['forceGC'] as bool?) ?? false;
    final topN = (req.arguments?['topN'] as num?)?.toInt() ?? 20;

    stderr.writeln(
        '[mcp:memory_snapshot] Fetching memory snapshot (forceGc=$forceGc, topN=$topN)');

    final profile =
        await _vmService!.getAllocationProfile(_isolateId!, gc: forceGc);
    final heapUsage = profile.memoryUsage?.heapUsage ?? 0;
    final heapCapacity = profile.memoryUsage?.heapCapacity ?? 0;
    final externalUsage = profile.memoryUsage?.externalUsage ?? 0;
    final heapUtilization =
        heapCapacity > 0 ? (heapUsage / heapCapacity) * 100 : 0.0;

    final members = profile.members ?? [];
    final validMembers =
        members.where((m) => m.classRef?.name != null).toList();

    final sortedBySize = List<ClassHeapStats>.from(validMembers)
      ..sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));
    final sortedBySizeFiltered =
        sortedBySize.where((m) => (m.bytesCurrent ?? 0) > 0).toList();

    final sortedByInstances = List<ClassHeapStats>.from(validMembers)
      ..sort((a, b) =>
          (b.instancesCurrent ?? 0).compareTo(a.instancesCurrent ?? 0));
    final sortedByInstancesFiltered =
        sortedByInstances.where((m) => (m.instancesCurrent ?? 0) > 0).toList();

    final output = [
      'MEMORY SNAPSHOT',
      '',
      'HEAP OVERVIEW',
      'Heap used: ${_formatBytes(heapUsage)}',
      'Heap capacity: ${_formatBytes(heapCapacity)}',
      'Utilization: ${heapUtilization.toStringAsFixed(1)}%',
      'External: ${_formatBytes(externalUsage)}',
      'Total: ${_formatBytes(heapUsage + externalUsage)}',
      if (forceGc) '(Snapshot taken after forced GC)',
      '',
      'TOP $topN CLASSES BY MEMORY',
    ];

    for (final member in sortedBySizeFiltered.take(topN)) {
      final bytesCurrent = member.bytesCurrent ?? 0;
      final instancesCurrent = member.instancesCurrent ?? 0;
      final className = member.classRef!.name!;
      final pct = heapUsage > 0
          ? ((bytesCurrent / heapUsage) * 100).toStringAsFixed(1)
          : '0.0';
      output.add('${_formatBytes(bytesCurrent)} ($pct%) | $instancesCurrent instances | $className');
    }

    output.add('');
    output.add('TOP 10 CLASSES BY INSTANCE COUNT');

    for (final member in sortedByInstancesFiltered.take(10)) {
      final bytesCurrent = member.bytesCurrent ?? 0;
      final instancesCurrent = member.instancesCurrent ?? 0;
      final className = member.classRef!.name!;
      output.add('$instancesCurrent instances | ${_formatBytes(bytesCurrent)} | $className');
    }

    const vmInternalClasses = {
      '_OneByteString',
      '_TwoByteString',
      'String',
      '_List',
      '_GrowableList',
      '_ImmutableList',
      '_Mint',
      '_Double',
      'bool',
      'Null',
      'int',
      'double',
      'Class',
      'ForwardingCorpse',
      'FreeListElement',
      'TypeParameter',
      'UnlinkedCall',
      'ICData',
      'Field',
      'Function',
      'Code',
      'Instructions',
      'ObjectPool',
      'PcDescriptors',
      'CodeSourceMap',
      'CompressedStackMaps',
      'Type',
      '_Type',
      'LibraryPrefix',
      '_FunctionType',
      'Namespace',
      'Library',
      'TypeArguments',
      'ClosureData',
      'SubtypeTestCache',
      'SingleTargetCache',
      'MegamorphicCache',
      'WeakProperty',
      'WeakReference',
      'FinalizerEntry',
      '_WeakProperty',
      '_WeakReference',
      'KernelProgramInfo',
      'Script',
      'Bytecode',
      '_Int8List',
      '_Uint8List',
      '_Uint16List',
      '_Uint32List',
      '_Int32List',
      '_Float32List',
      '_Float64List',
      '_ExternalOneByteString',
      'Array',
      'GrowableObjectArray',
      'Context',
      'ContextScope',
      'RegExp',
      '_RegExp',
      'LocalVarDescriptors',
      'ExceptionHandlers',
      'ParameterTypeCheck',
      'ApiErrorClass',
      'LanguageError',
      'Bool',
      'Sentinel',
      'FfiTrampolineData',
    };

    bool isVmInternal(String name) {
      if (vmInternalClasses.contains(name)) return true;
      if (name.startsWith('_') &&
          name.length < 20 &&
          !name.contains('State') &&
          !name.contains('Controller')) {
        return true;
      }
      return false;
    }

    final appClasses = sortedByInstancesFiltered
        .where((m) => !isVmInternal(m.classRef!.name!))
        .toList();

    if (appClasses.isNotEmpty) {
      output.add('');
      output.add('APP & FRAMEWORK CLASSES');
      for (final cls in appClasses.take(20)) {
        final bytesCurrent = cls.bytesCurrent ?? 0;
        final instancesCurrent = cls.instancesCurrent ?? 0;
        final className = cls.classRef!.name!;
        output.add('$instancesCurrent instances | ${_formatBytes(bytesCurrent)} | $className');
      }
    }

    final suspiciousClasses =
        appClasses.where((m) => (m.instancesCurrent ?? 0) > 500).toList();

    if (suspiciousClasses.isNotEmpty) {
      output.add('');
      output.add('POTENTIAL CONCERNS');
      for (final cls in suspiciousClasses.take(5)) {
        final bytesCurrent = cls.bytesCurrent ?? 0;
        final instancesCurrent = cls.instancesCurrent ?? 0;
        final className = cls.classRef!.name!;
        output.add('- $className: $instancesCurrent instances (${_formatBytes(bytesCurrent)}) - check for leaks or excessive allocations');
      }
    }

    if (heapUtilization > 85.0) {
      output.add('');
      output.add(
          'WARNING: Heap utilization above 85%. The app may be at risk of OOM. Consider reducing memory footprint.');
    }

    final structuredData = {
      'heapUsage': heapUsage,
      'heapCapacity': heapCapacity,
      'externalUsage': externalUsage,
      'heapUtilization': heapUtilization,
      'top_classes': sortedBySizeFiltered.take(topN).map((m) => {
        'class': m.classRef!.name!,
        'bytes': m.bytesCurrent ?? 0,
        'instances': m.instancesCurrent ?? 0,
      }).toList(),
      'top_instances': sortedByInstancesFiltered.take(10).map((m) => {
        'class': m.classRef!.name!,
        'bytes': m.bytesCurrent ?? 0,
        'instances': m.instancesCurrent ?? 0,
      }).toList(),
      'app_classes': appClasses.take(20).map((m) => {
        'class': m.classRef!.name!,
        'bytes': m.bytesCurrent ?? 0,
        'instances': m.instancesCurrent ?? 0,
      }).toList(),
    };

    return _serializeDualFormat(
      title: 'Memory Snapshot Summary',
      markdownBody: output.join('\n'),
      structuredData: structuredData,
      format: req.arguments?['format'] as String?,
    );
  }

  void _sortDeltas(List<Map<String, dynamic>> deltas, String instDeltaKey, String bytesDeltaKey) {
    deltas.sort((a, b) {
      final cmp = (b[instDeltaKey] as int)
          .abs()
          .compareTo((a[instDeltaKey] as int).abs());
      if (cmp != 0) return cmp;
      return (b[bytesDeltaKey] as int)
          .abs()
          .compareTo((a[bytesDeltaKey] as int).abs());
    });
  }

  String _formatAllocationDiffTable(List<Map<String, dynamic>> deltas, {int limit = 20}) {
    if (deltas.isEmpty) {
      return 'No heap allocation changes recorded during the profiling window.\n';
    }
    final md = StringBuffer();
    md.writeln(
        '| Class | Instances Delta | Bytes Delta | Before (Count / Size) | After (Count / Size) |');
    md.writeln('| :--- | :--- | :--- | :--- | :--- |');
    for (final d in deltas.take(limit)) {
      final instDelta = d['instances_delta'] as int;
      final bytesDelta = d['bytes_delta'] as int;
      final instDeltaStr = instDelta > 0 ? '+$instDelta' : '$instDelta';
      final byteDeltaStr = bytesDelta > 0 ? '+${_formatBytes(bytesDelta)}' : _formatBytes(bytesDelta);
      
      md.writeln(
        '| ${d['class']} | $instDeltaStr | $byteDeltaStr | '
        '${d['instances_before']} / ${_formatBytes(d['bytes_before'] as int)} | '
        '${d['instances_after']} / ${_formatBytes(d['bytes_after'] as int)} |',
      );
    }
    if (deltas.length > limit) {
      md.writeln('\n_...and ${deltas.length - limit} more classes._');
    }
    return md.toString();
  }
}

class _ClassAllocation {
  final String name;
  final int bytes;
  final int instances;

  _ClassAllocation({
    required this.name,
    required this.bytes,
    required this.instances,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'bytes': bytes,
      'instances': instances,
    };
  }
}

class _MemorySnapshot {
  final String name;
  final int timestamp;
  final int heapUsage;
  final int heapCapacity;
  final int externalUsage;
  final List<_ClassAllocation> topClasses;

  _MemorySnapshot({
    required this.name,
    required this.timestamp,
    required this.heapUsage,
    required this.heapCapacity,
    required this.externalUsage,
    required this.topClasses,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'timestamp': timestamp,
      'heapUsage': heapUsage,
      'heapCapacity': heapCapacity,
      'externalUsage': externalUsage,
      'topClasses': topClasses.map((c) => c.toMap()).toList(),
    };
  }
}
