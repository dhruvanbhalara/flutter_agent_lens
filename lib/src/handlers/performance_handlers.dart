part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for diagnosing frame jank and capturing CPU profiles.
extension PerformanceHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleDiagnoseJank(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final duration = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 3;

    try {
      stderr.writeln(
          '[mcp:diagnose_jank] Starting jank diagnosis, duration=${duration}s');
      // Fetch frame rendering events
      final frameEvents = <Map<String, dynamic>>[];

      // Enable and query timeline records
      await _vmService!.setVMTimelineFlags(['Embedder', 'Dart', 'GC', 'API']);
      await _vmService!.clearVMTimeline();

      await Future.delayed(Duration(seconds: duration));

      final timeline = await _vmService!.getVMTimeline();

      // Check timeline events
      final events = timeline.traceEvents ?? [];
      var jankyFrames = 0;
      var totalFrames = 0;

      for (final event in events) {
        final eventName = event.json?['name'] as String?;
        if (eventName == 'GPURasterizer::Draw' ||
            eventName == 'Animator::BeginFrame') {
          totalFrames++;
          final dur = event.json?['dur'] as num? ?? 0;
          if (dur > 16666) {
            // 16.6ms in microseconds
            jankyFrames++;
            frameEvents.add({
              'event': eventName,
              'duration_ms': dur / 1000.0,
              'timestamp': event.json?['ts'],
            });
          }
        }
      }

      final jankPercentage =
          totalFrames > 0 ? (jankyFrames / totalFrames) * 100 : 0.0;
      stderr.writeln(
          '[mcp:diagnose_jank] Collected ${events.length} timeline events, $jankyFrames janky frames');
      final mdBuffer = StringBuffer('### Jank Diagnostic Report\n\n')
        ..writeln('- **Total Frame Events Sampled**: $totalFrames')
        ..writeln(
            '- **Janky Frame Events (> 16.6ms)**: $jankyFrames ($jankPercentage%)')
        ..writeln();

      if (jankyFrames > 0) {
        mdBuffer.writeln('| Event | Duration (ms) | Severity |');
        mdBuffer.writeln('| :--- | :--- | :--- |');
        for (final f in frameEvents.take(10)) {
          final dur = f['duration_ms'] as double;
          final severity = dur > 33.3 ? 'CRITICAL (>33ms)' : 'WARNING (>16ms)';
          mdBuffer.writeln(
              '| ${f['event']} | ${dur.toStringAsFixed(2)} | $severity |');
        }
      } else {
        mdBuffer.writeln(
            'Clean Render Cycle: No frame events exceeded the 16.6ms budget.');
      }

      return _serializeDualFormat(
        title: '### Jank Diagnosis',
        markdownBody: mdBuffer.toString(),
        structuredData: {
          'total_frames': totalFrames,
          'janky_frames': jankyFrames,
          'jank_percentage': jankPercentage,
          'critical_events': frameEvents,
        },
      );
    } catch (e) {
      stderr.writeln('[mcp:diagnose_jank] ERROR: $e');
      return CallToolResult(
          content: [TextContent(text: 'Jank diagnosis failed: $e')],
          isError: true);
    }
  }

  Future<CallToolResult> handleHotReload(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();

    try {
      stderr.writeln('[mcp:hot_reload] Triggering hot reload via reloadSources...');
      final report = await _vmService!.reloadSources(_isolateId!, force: false);
      final success = report.success ?? false;

      if (success) {
        return CallToolResult(
            content: [TextContent(text: 'Hot reload completed successfully via reloadSources.')]);
      } else {
        final notices = report.json?['notices'] as List<dynamic>? ?? [];
        final errors = notices
            .map((n) => n['message']?.toString() ?? n.toString())
            .join('\n');
        stderr.writeln('[mcp:hot_reload] reloadSources failed: $errors. Falling back to reassemble.');
        return _fallbackReassemble('Hot reload sources failed:\n$errors');
      }
    } catch (e) {
      stderr.writeln('[mcp:hot_reload] reloadSources threw exception: $e. Falling back to reassemble.');
      return _fallbackReassemble('Hot reload via reloadSources failed ($e).');
    }
  }

  Future<CallToolResult> _fallbackReassemble(String originalFailureReason) async {
    try {
      stderr.writeln('[mcp:hot_reload] Attempting fallback UI reassemble...');
      await _vmService!.callServiceExtension(
        'ext.flutter.reassemble',
        isolateId: _isolateId!,
      );
      return CallToolResult(
        content: [
          TextContent(
            text: '$originalFailureReason\n'
                'Successfully fell back to triggering a widget tree reassemble (UI layout refreshed).',
          )
        ],
      );
    } catch (fallbackError) {
      stderr.writeln('[mcp:hot_reload] Fallback reassemble failed: $fallbackError');
      return CallToolResult(
        content: [
          TextContent(
            text: '$originalFailureReason\n'
                'Fallback to widget tree reassemble also failed: $fallbackError',
          )
        ],
        isError: true,
      );
    }
  }

  Future<CallToolResult> handleHotRestart(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();

    try {
      stderr.writeln('[mcp:hot_restart] Fetching isolate information to check extensions...');
      final isolate = await _vmService!.getIsolate(_isolateId!);
      final extensions = isolate.extensionRPCs ?? [];
      final hasWebRestart = extensions.contains('ext.flutter.restart');

      if (hasWebRestart) {
        stderr.writeln('[mcp:hot_restart] Web restart extension found. Triggering ext.flutter.restart...');
        await _vmService!.callServiceExtension(
          'ext.flutter.restart',
          isolateId: _isolateId!,
        );

        // Refresh isolate ID and clear library cache
        final vm = await _vmService!.getVM();
        if (vm.isolates != null && vm.isolates!.isNotEmpty) {
          _isolateId = vm.isolates!.first.id!;
          _cachedLibraryId = null;
          stderr.writeln('[mcp:hot_restart] Refreshed main isolate ID: $_isolateId');
        }

        return CallToolResult(
          content: [TextContent(text: 'Web hot restart completed successfully.')],
        );
      } else {
        stderr.writeln('[mcp:hot_restart] Web restart extension not found. Triggering host hotRestart...');
        final response = await _vmService!.callMethod(
          'hotRestart',
          args: <String, Object?>{'pause': false},
        );

        final error = response.json?['error'];
        if (error != null) {
          return CallToolResult(
            content: [TextContent(text: 'Hot restart failed: $error')],
            isError: true,
          );
        }

        // Refresh isolate ID and clear library cache
        final vm = await _vmService!.getVM();
        if (vm.isolates != null && vm.isolates!.isNotEmpty) {
          _isolateId = vm.isolates!.first.id!;
          _cachedLibraryId = null;
          stderr.writeln('[mcp:hot_restart] Refreshed main isolate ID: $_isolateId');
        }

        return CallToolResult(
          content: [TextContent(text: 'Hot restart completed successfully.')],
        );
      }
    } catch (e) {
      stderr.writeln('[mcp:hot_restart] ERROR: $e');
      var message = 'Hot restart error: $e';
      if (e is RPCError && e.code == -32601) {
        message = 'Hot restart is not supported by the current connection. '
            'This typically happens if the application was not started using a Flutter tool runner (like "flutter run") '
            'that registers the "hotRestart" service, or if the runner is disconnected.';
      }
      return CallToolResult(
        content: [TextContent(text: message)],
        isError: true,
      );
    }
  }

  Future<CallToolResult> _handleGetCpuProfile(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final duration = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 3;

    try {
      stderr.writeln(
          '[mcp:cpu_profile] Starting CPU profile, duration=${duration}s');
      // 1. Flush existing samples
      await _vmService!.clearCpuSamples(_isolateId!);

      // 2. Wait to collect fresh profiling data
      await Future.delayed(Duration(seconds: duration));

      // 3. Retrieve all accumulated CPU samples
      final cpuSamples =
          await _vmService!.getCpuSamples(_isolateId!, 0, 999999999999);
      final functions = cpuSamples.functions ?? [];

      final hotspots = <Map<String, dynamic>>[];
      final mdBuffer =
          StringBuffer('### CPU Execution Hotspots (Exclusive Ticks)\n\n');

      for (final dynamic f in functions) {
        if (f is ProfileFunction) {
          final func = f.function;
          final String name;
          if (func is FuncRef) {
            name = func.name ?? 'unknown';
          } else {
            name = func?.toString() ?? 'unknown';
          }

          final url = f.resolvedUrl ?? '';
          final resolvedPath = _pathResolver != null
              ? _pathResolver!.resolveToAbsolutePath(url)
              : url;

          hotspots.add({
            'name': name,
            'exclusive_ticks': f.exclusiveTicks ?? 0,
            'inclusive_ticks': f.inclusiveTicks ?? 0,
            'location': resolvedPath,
          });
        }
      }

      // Sort by exclusive ticks descending
      hotspots.sort((a, b) =>
          (b['exclusive_ticks'] as int).compareTo(a['exclusive_ticks'] as int));
      stderr.writeln(
          '[mcp:cpu_profile] Collected ${cpuSamples.sampleCount} samples, ${hotspots.length} functions');

      if (hotspots.isEmpty) {
        mdBuffer.writeln('No CPU sampling ticks recorded in the window.');
      } else {
        mdBuffer.writeln(
            '| Function | Exclusive Ticks | Inclusive Ticks | Source Location |');
        mdBuffer.writeln('| :--- | :--- | :--- | :--- |');
        for (final h in hotspots.take(15)) {
          mdBuffer.writeln(
              '| **${h['name']}** | ${h['exclusive_ticks']} | ${h['inclusive_ticks']} | `${h['location']}` |');
        }
      }

      return _serializeDualFormat(
        title: '### CPU Profiler Diagnostic Report',
        markdownBody: mdBuffer.toString(),
        structuredData: {
          'duration_seconds': duration,
          'total_samples': cpuSamples.sampleCount ?? 0,
          'hotspots': hotspots,
        },
      );
    } catch (e) {
      stderr.writeln('[mcp:cpu_profile] ERROR: $e');
      return CallToolResult(
          content: [TextContent(text: 'CPU profiling failed: $e')],
          isError: true);
    }
  }
}
