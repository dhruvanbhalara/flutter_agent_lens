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
      stderr.writeln(
          '[mcp:hot_reload] Triggering hot reload via reloadSources...');
      final report = await _vmService!.reloadSources(_isolateId!, force: false);
      final success = report.success ?? false;

      if (success) {
        return CallToolResult(content: [
          TextContent(
              text: 'Hot reload completed successfully via reloadSources.\n'
                  'Note: Hot reload applies changes only if they were compiled by a compiler '
                  'host (like an active "flutter run" session or your IDE). If you edited files '
                  'but do not see changes, ensure the compiler is active.')
        ]);
      } else {
        final notices = report.json?['notices'] as List<dynamic>? ?? [];
        final errors = notices
            .map((n) => n['message']?.toString() ?? n.toString())
            .join('\n');
        stderr.writeln(
            '[mcp:hot_reload] reloadSources failed: $errors. Falling back to reassemble.');
        return _fallbackReassemble('Hot reload sources failed:\n$errors');
      }
    } catch (e) {
      stderr.writeln(
          '[mcp:hot_reload] reloadSources threw exception: $e. Falling back to reassemble.');
      return _fallbackReassemble('Hot reload via reloadSources failed ($e).');
    }
  }

  Future<CallToolResult> _fallbackReassemble(
      String originalFailureReason) async {
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
                'Fell back to rebuild the widget tree (reassemble).\n'
                'Note: This refreshes the UI layout but does not load new code changes from disk '
                'unless they were first compiled by a hot runner.',
          )
        ],
      );
    } catch (fallbackError) {
      stderr.writeln(
          '[mcp:hot_reload] Fallback reassemble failed: $fallbackError');
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
      stderr.writeln(
          '[mcp:hot_restart] Fetching isolate information to check extensions...');
      final isolate = await _vmService!.getIsolate(_isolateId!);
      final extensions = isolate.extensionRPCs ?? [];
      final hasWebRestart = extensions.contains('ext.flutter.restart');

      if (hasWebRestart) {
        stderr.writeln(
            '[mcp:hot_restart] Web restart extension found. Triggering ext.flutter.restart...');
        await _vmService!.callServiceExtension(
          'ext.flutter.restart',
          isolateId: _isolateId!,
        );

        // Refresh isolate ID and clear library cache
        final vm = await _vmService!.getVM();
        if (vm.isolates != null && vm.isolates!.isNotEmpty) {
          _isolateId = vm.isolates!.first.id!;
          _cachedLibraryId = null;
          stderr.writeln(
              '[mcp:hot_restart] Refreshed main isolate ID: $_isolateId');
        }

        return CallToolResult(
          content: [
            TextContent(
              text: 'Web hot restart completed successfully.\n'
                  'Note: Hot restart resets state but requires a compiler runner (like "flutter run") '
                  'to load updated Dart files from disk.',
            )
          ],
        );
      } else {
        stderr.writeln(
            '[mcp:hot_restart] Web restart extension not found. Triggering host hotRestart...');
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
          stderr.writeln(
              '[mcp:hot_restart] Refreshed main isolate ID: $_isolateId');
        }

        return CallToolResult(
          content: [
            TextContent(
              text: 'Hot restart completed successfully.\n'
                  'Note: Hot restart resets state but requires a compiler runner (like "flutter run") '
                  'to load updated Dart files from disk.',
            )
          ],
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

  Future<CallToolResult> _handleStartProfiling(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    if (_isProfiling) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'A profiling session is already active. Call stop_profiling first.')
        ],
        isError: true,
      );
    }

    try {
      stderr
          .writeln('[mcp:profiling] Starting performance profiling session...');
      await _vmService!.clearVMTimeline();
      await _vmService!
          .setVMTimelineFlags(['Embedder', 'Dart', 'GC', 'API', 'Compiler']);

      double fpsVal = 60.0;
      try {
        final fpsResponse = await _vmService!.callServiceExtension(
          'ext.flutter.getDisplayRefreshRate',
          isolateId: _isolateId,
        );
        fpsVal = (fpsResponse.json?['fps'] as num?)?.toDouble() ?? 60.0;
      } catch (_) {}

      _isProfiling = true;
      _profilingStartTime = DateTime.now().millisecondsSinceEpoch;
      _targetFps = fpsVal;

      return CallToolResult(
        content: [
          TextContent(
            text:
                'Profiling started. Interact with the app now, then call `stop_profiling` to get the analysis.',
          )
        ],
      );
    } catch (e) {
      _isProfiling = false;
      return CallToolResult(
        content: [TextContent(text: 'Failed to start profiling: $e')],
        isError: true,
      );
    }
  }

  Future<CallToolResult> _handleStopProfiling(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    if (!_isProfiling) {
      return CallToolResult(
        content: [
          TextContent(
              text: 'No active profiling session. Call start_profiling first.')
        ],
        isError: true,
      );
    }

    try {
      stderr
          .writeln('[mcp:profiling] Stopping performance profiling session...');
      _isProfiling = false;
      final durationMs =
          DateTime.now().millisecondsSinceEpoch - _profilingStartTime!;

      // Get timeline trace events
      final timeline = await _vmService!.getVMTimeline();
      final events = timeline.traceEvents ?? [];

      // Reset timeline flags
      await _vmService!.setVMTimelineFlags([]);

      final targetFps = _targetFps ?? 60.0;
      final targetFrameTimeMs = 1000.0 / targetFps;

      // Analyze frames
      var totalFrames = 0;
      var jankyFrames = 0;
      var maxFrameTimeMs = 0.0;
      final frameDurations = <double>[];

      bool isFrameEvent(String name) {
        final n = name.toLowerCase();
        return n == 'frame' ||
            n == 'vsync' ||
            n.contains('animator') ||
            n.contains('beginframe') ||
            n.contains('onanimatorbeginframe') ||
            n.contains('shell::onanimatorbeginframe') ||
            n == 'gpurasterizer::draw' ||
            n == 'rasterizer::dodraw' ||
            n.contains('pipeline produce') ||
            n.contains('pipeline consume');
      }

      for (final event in events) {
        final name = event.json?['name'] as String?;
        if (name == null) continue;

        final ph = event.json?['ph'] as String?;
        final dur = event.json?['dur'] as num?;

        if (ph == 'X' && dur != null && isFrameEvent(name)) {
          final ms = dur / 1000.0;
          frameDurations.add(ms);
          if (ms > maxFrameTimeMs) maxFrameTimeMs = ms;
          if (ms > targetFrameTimeMs) jankyFrames++;
          totalFrames++;
        }
      }

      // Sort frame durations for percentiles
      frameDurations.sort();
      final p90 = frameDurations.isNotEmpty
          ? frameDurations[(frameDurations.length * 0.9).floor()]
          : 0.0;
      final p99 = frameDurations.isNotEmpty
          ? frameDurations[(frameDurations.length * 0.99).floor()]
          : 0.0;
      final avgFrameTime = frameDurations.isNotEmpty
          ? frameDurations.reduce((a, b) => a + b) / frameDurations.length
          : 0.0;
      final jankPct = totalFrames > 0 ? (jankyFrames / totalFrames) * 100 : 0.0;

      // Group CPU hotspots from timeline trace events where ph == 'X'
      final cpuEventMap = <String, List<double>>{};
      for (final event in events) {
        final ph = event.json?['ph'] as String?;
        final dur = event.json?['dur'] as num?;
        final name = event.json?['name'] as String?;
        if (ph == 'X' && dur != null && dur > 0 && name != null) {
          cpuEventMap.putIfAbsent(name, () => []).add(dur / 1000.0);
        }
      }

      final cpuHotspots = <Map<String, dynamic>>[];
      cpuEventMap.forEach((name, durations) {
        final totalDur = durations.reduce((a, b) => a + b);
        final maxDur = durations.reduce((a, b) => a > b ? a : b);
        final avgDur = totalDur / durations.length;

        String severity = 'low';
        if (maxDur > 100.0) {
          severity = 'critical';
        } else if (maxDur > 32.0) {
          severity = 'high';
        } else if (maxDur > 16.0) {
          severity = 'medium';
        }

        cpuHotspots.add({
          'name': name,
          'totalDurationMs': double.parse(totalDur.toStringAsFixed(2)),
          'callCount': durations.length,
          'avgDurationMs': double.parse(avgDur.toStringAsFixed(2)),
          'maxDurationMs': double.parse(maxDur.toStringAsFixed(2)),
          'severity': severity,
        });
      });

      // Sort by total duration descending
      cpuHotspots.sort((a, b) => (b['totalDurationMs'] as double)
          .compareTo(a['totalDurationMs'] as double));

      // Build phase breakdown
      Map<String, dynamic> analyzePhase(
          String phaseName, List<String> patterns) {
        final phaseDurations = <double>[];
        for (final event in events) {
          final ph = event.json?['ph'] as String?;
          final dur = event.json?['dur'] as num?;
          final name = event.json?['name'] as String?;
          if (ph == 'X' && dur != null && name != null) {
            final lower = name.toLowerCase();
            if (patterns.any((p) => lower.contains(p))) {
              phaseDurations.add(dur / 1000.0);
            }
          }
        }
        final total = phaseDurations.isNotEmpty
            ? phaseDurations.reduce((a, b) => a + b)
            : 0.0;
        final max = phaseDurations.isNotEmpty
            ? phaseDurations.reduce((a, b) => a > b ? a : b)
            : 0.0;
        final avg =
            phaseDurations.isNotEmpty ? total / phaseDurations.length : 0.0;
        return {
          'totalTimeMs': double.parse(total.toStringAsFixed(2)),
          'avgTimeMs': double.parse(avg.toStringAsFixed(2)),
          'maxTimeMs': double.parse(max.toStringAsFixed(2)),
          'count': phaseDurations.length,
        };
      }

      final buildPhase = analyzePhase('Build', [
        'build',
        'widget',
        'createelement',
        'updatechild',
        'performrebuild'
      ]);
      final layoutPhase = analyzePhase('Layout', [
        'layout',
        'performlayout',
        'flushlayout',
        'renderflex',
        'renderbox'
      ]);
      final paintPhase = analyzePhase(
          'Paint', ['paint', 'flushpaint', 'compositeframe', 'rasterizer']);

      // Generate output report
      final output = [
        '═══════════════════════════════════════════════════════════',
        '  FLUTTER PERFORMANCE ANALYSIS REPORT',
        '═══════════════════════════════════════════════════════════',
        '',
        '  SUMMARY',
        '───────────────────────────────────────────────────────────',
        'Profiled for ${(durationMs / 1000.0).toStringAsFixed(1)}s, captured $totalFrames frames (${events.length} raw events)',
        'Average frame time: ${avgFrameTime.toStringAsFixed(2)}ms (target: ${targetFrameTimeMs.toStringAsFixed(1)}ms)',
        if (jankyFrames > 0)
          'Warning: $jankyFrames janky frames detected (${jankPct.toStringAsFixed(1)}% of total)'
        else
          'No jank detected - all frames within budget',
        'Worst frame: ${maxFrameTimeMs.toStringAsFixed(2)}ms (${(maxFrameTimeMs / targetFrameTimeMs).toStringAsFixed(1)}x target)',
        '',
        '  FRAME ANALYSIS',
        '───────────────────────────────────────────────────────────',
        'Total frames: $totalFrames',
        'Average frame time: ${avgFrameTime.toStringAsFixed(2)}ms',
        'P90 frame time: ${p90.toStringAsFixed(2)}ms',
        'P99 frame time: ${p99.toStringAsFixed(2)}ms',
        'Max frame time: ${maxFrameTimeMs.toStringAsFixed(2)}ms',
        'Jank frames: $jankyFrames ($jankPct%)',
        'Target: ${targetFrameTimeMs.toStringAsFixed(1)}ms (${targetFps.round()}fps)',
        '',
        '  PHASE BREAKDOWN',
        '───────────────────────────────────────────────────────────',
        'Build:  avg ${buildPhase['avgTimeMs']}ms | max ${buildPhase['maxTimeMs']}ms | ${buildPhase['count']} calls',
        'Layout: avg ${layoutPhase['avgTimeMs']}ms | max ${layoutPhase['maxTimeMs']}ms | ${layoutPhase['count']} calls',
        'Paint:  avg ${paintPhase['avgTimeMs']}ms | max ${paintPhase['maxTimeMs']}ms | ${paintPhase['count']} calls',
        '',
      ];

      if (cpuHotspots.isNotEmpty) {
        output.add('CPU HOTSPOTS');
        output
            .add('───────────────────────────────────────────────────────────');
        for (final h in cpuHotspots.take(10)) {
          final severity = h['severity'] as String;
          final severityLabel = severity == 'critical'
              ? '[CRITICAL]'
              : severity == 'high'
                  ? '[HIGH]    '
                  : severity == 'medium'
                      ? '[MEDIUM]  '
                      : '[LOW]     ';
          output.add('$severityLabel ${h['name']}');
          output.add(
              '   Total: ${h['totalDurationMs']}ms | Avg: ${h['avgDurationMs']}ms | Max: ${h['maxDurationMs']}ms | Calls: ${h['callCount']}');
        }
        output.add('');
      }

      // Generate recommendations
      final recommendations = <String>[];
      if (events.isEmpty) {
        recommendations.add(
            'No timeline events were captured. Make sure to interact with the app.');
      } else {
        if (jankPct > 10.0) {
          recommendations.add(
              'Significant jank detected. Profile in release/profile mode to get accurate numbers.');
        }
        if ((buildPhase['maxTimeMs'] as double) > 16.0) {
          recommendations.add(
              'Build phase exceeds frame budget. Use const constructors and break up large widget trees.');
        }
        if ((buildPhase['count'] as int) > totalFrames * 3) {
          recommendations.add(
              'Excessive widget rebuilds detected. Wrap in const constructors or use context.select().');
        }
        if ((layoutPhase['maxTimeMs'] as double) > 16.0) {
          recommendations.add(
              'Layout phase is slow. Look for intrinsic dimensions or deeply nested flex layouts.');
        }
        if ((paintPhase['maxTimeMs'] as double) > 16.0) {
          recommendations.add(
              'Paint phase is slow. Use RepaintBoundary to isolate repainting of heavy animated components.');
        }
        for (final h
            in cpuHotspots.where((h) => h['severity'] == 'critical').take(3)) {
          recommendations.add(
              'Critical hotspot: "${h['name']}" taking ${h['maxDurationMs']}ms.');
        }
      }
      if (recommendations.isEmpty) {
        recommendations.add(
            'Performance looks good! No major issues detected in this session.');
      }

      output.add('RECOMMENDATIONS');
      output.add('───────────────────────────────────────────────────────────');
      for (final rec in recommendations) {
        output.add('• $rec');
      }

      return _serializeDualFormat(
        title: '### Performance Profiling Analysis',
        markdownBody: output.join('\n'),
        structuredData: {
          'duration_ms': durationMs,
          'total_events_collected': events.length,
          'frame_analysis': {
            'total_frames': totalFrames,
            'jank_frames': jankyFrames,
            'jank_percentage': jankPct,
            'average_frame_time_ms': avgFrameTime,
            'max_frame_time_ms': maxFrameTimeMs,
            'p90_frame_time_ms': p90,
            'p99_frame_time_ms': p99,
          },
          'build_phase': buildPhase,
          'layout_phase': layoutPhase,
          'paint_phase': paintPhase,
          'cpu_hotspots': cpuHotspots,
          'recommendations': recommendations,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:profiling] ERROR: $e');
      stderr.writeln('[mcp:profiling] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Failed to stop profiling: $e')],
        isError: true,
      );
    }
  }
}
