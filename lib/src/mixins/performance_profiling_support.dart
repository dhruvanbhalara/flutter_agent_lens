import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import '../enums/mcp_tool.dart';
import '../extensions/call_tool_request_x.dart';
import 'vm_connection_support.dart';
import 'connection_support.dart';

/// Support mixin providing tools for frame analysis, CPU sampling, and reload/restart execution.
base mixin PerformanceProfilingSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  static const int _kFrameBudgetUs = 16666;

  /// Whether the CPU timeline sampling or profiling is active.
  bool isProfiling = false;

  /// Timestamp in milliseconds when the performance profiling session was started.
  int? profilingStartTime;

  /// The target display refresh rate (FPS) of the connected device.
  double? targetFps;

  /// Registers performance profiling and reload/restart tools.
  void registerPerformanceTools() {
    registerTool(
      Tool(
        name: McpTool.profiling.name,
        description: 'Manage CPU & jank profiling. '
            'Actions: start (begin session), stop (end and get report), '
            'get_cpu (sample CPU hotspots), diagnose_jank (check frame times).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description: 'Action: start, stop, get_cpu, diagnose_jank.',
            ),
            'duration_seconds': durationSchema(),
            'limit': limitSchema(defaultValue: 15),
          },
          required: ['action'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
        ),
      ),
      _handleProfiling,
    );

    registerTool(
      Tool(
        name: McpTool.hotReload.name,
        description: 'Trigger a hot reload.',
        inputSchema: emptySchema(),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
        ),
      ),
      handleHotReload,
    );

    registerTool(
      Tool(
        name: McpTool.hotRestart.name,
        description: 'Trigger a hot restart of the application.',
        inputSchema: emptySchema(),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: false,
        ),
      ),
      handleHotRestart,
    );
  }

  /// Clears performance profiling state and resets targets.
  Future<void> cleanupPerformanceProfiling() async {
    isProfiling = false;
    profilingStartTime = null;
    targetFps = null;
    final service = vmService;
    if (service != null) {
      try {
        await service.setVMTimelineFlags([]);
      } catch (e) {
        stderr.writeln(
            '[mcp:profiling] Error resetting timeline flags on cleanup: $e');
      }
    }
  }

  /// Handles the diagnose_jank tool request.
  Future<CallToolResult> _handleDiagnoseJank(CallToolRequest req) async {
    final duration = (req.arg<num>('duration_seconds'))?.toInt() ?? 3;
    stderr.writeln(
        '[mcp:diagnose_jank] Starting jank diagnosis, duration=${duration}s');

    final frameEvents = <Map<String, dynamic>>[];
    await vmService!.setVMTimelineFlags(['Embedder', 'Dart', 'GC', 'API']);
    await vmService!.clearVMTimeline();

    Timeline timeline;
    try {
      await Future<void>.delayed(Duration(seconds: duration));
      timeline = await vmService!.getVMTimeline();
    } finally {
      try {
        await vmService!.setVMTimelineFlags([]);
      } catch (e) {
        stderr
            .writeln('[mcp:diagnose_jank] Error resetting timeline flags: $e');
      }
    }
    final events = timeline.traceEvents ?? [];
    var jankyFrames = 0;
    var totalFrames = 0;

    for (final event in events) {
      final eventName = event.json?['name'] as String?;
      if (eventName == 'GPURasterizer::Draw' ||
          eventName == 'Animator::BeginFrame') {
        totalFrames++;
        final dur = event.json?['dur'] as num? ?? 0;
        if (dur > _kFrameBudgetUs) {
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
    final mdBuffer = StringBuffer('Jank Diagnostic Report\n\n')
      ..writeln('- Total Frame Events Sampled: $totalFrames')
      ..writeln(
          '- Janky Frame Events (> 16.6ms): $jankyFrames ($jankPercentage%)')
      ..writeln();

    final limit = (req.arg<num>('limit'))?.toInt() ?? 15;
    if (jankyFrames > 0) {
      mdBuffer.writeln('| Event | Duration (ms) | Severity |');
      mdBuffer.writeln('| :--- | :--- | :--- |');
      for (final f in frameEvents.take(limit)) {
        final dur = f['duration_ms'] as double;
        final severity = dur > 33.3 ? 'CRITICAL (>33ms)' : 'WARNING (>16ms)';
        mdBuffer.writeln(
            '| ${f['event']} | ${dur.toStringAsFixed(2)} | $severity |');
      }
    } else {
      mdBuffer.writeln(
          'Clean Render Cycle: No frame events exceeded the 16.6ms budget.');
    }

    return serializeDualFormat(
      title: 'Jank Diagnosis',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'total_frames': totalFrames,
        'janky_frames': jankyFrames,
        'jank_percentage': jankPercentage,
        'critical_events': frameEvents,
      },
    );
  }

  /// Handles the hot_reload tool request, utilizing DTD if connected.
  Future<CallToolResult> handleHotReload(CallToolRequest req) async {
    bool dtdSuccess = false;
    if (this is ConnectionSupport) {
      final dtd = this as ConnectionSupport;
      if (dtd.dtdClient != null && vmServiceUri != null) {
        stderr.writeln(
            '[mcp:hot_reload] Triggering ConnectedApp.hotReload via DTD...');
        try {
          await dtd.dtdClient!.call(
            'ConnectedApp',
            'hotReload',
            params: {'vmServiceUri': vmServiceUri},
          );
          dtdSuccess = true;
        } catch (e) {
          stderr.writeln(
              '[mcp:hot_reload] DTD call failed: $e. Falling back to direct VM Service...');
        }
      }
    }

    if (!dtdSuccess) {
      final reloadMethod = registeredMethodsForService['reloadSources'] ??
          registeredMethodsForService['hotReload'];
      if (reloadMethod != null) {
        stderr.writeln(
            '[mcp:hot_reload] Triggering registered service $reloadMethod...');
        await vmService!.callMethod(
          reloadMethod,
          args: {'isolateId': isolateId!},
        );
      } else {
        stderr.writeln('[mcp:hot_reload] Triggering ext.flutter.reassemble...');
        await vmService!.callServiceExtension(
          'ext.flutter.reassemble',
          isolateId: isolateId!,
        );
      }
    }

    return CallToolResult(content: [
      TextContent(
        text: 'Hot reload triggered successfully.\n'
            'UI has been reassembled. Note: To load new code changes from disk, '
            'save the files in your editor (VS Code, IntelliJ) to let the compiler build them first.',
      )
    ]);
  }

  /// Handles the hot_restart tool request, utilizing DTD if connected.
  Future<CallToolResult> handleHotRestart(CallToolRequest req) async {
    bool dtdSuccess = false;
    if (this is ConnectionSupport) {
      final dtd = this as ConnectionSupport;
      if (dtd.dtdClient != null && vmServiceUri != null) {
        stderr.writeln(
            '[mcp:hot_restart] Triggering ConnectedApp.hotRestart via DTD...');
        try {
          await dtd.dtdClient!.call(
            'ConnectedApp',
            'hotRestart',
            params: {'vmServiceUri': vmServiceUri},
          );
          dtdSuccess = true;
        } catch (e) {
          stderr.writeln(
              '[mcp:hot_restart] DTD call failed: $e. Falling back to direct VM Service...');
        }
      }
    }

    if (!dtdSuccess) {
      final hotRestartMethod = registeredMethodsForService['hotRestart'] ??
          registeredMethodsForService['restart'];
      if (hotRestartMethod != null) {
        stderr.writeln(
            '[mcp:hot_restart] Triggering registered service $hotRestartMethod...');
        await vmService!.callMethod(hotRestartMethod);
      } else {
        stderr.writeln(
            '[mcp:hot_restart] Checking for restart service extensions...');
        final isolate = await vmService!.getIsolate(isolateId!);
        final extensions = isolate.extensionRPCs ?? [];

        if (extensions.contains('ext.flutter.restart')) {
          stderr.writeln('[mcp:hot_restart] Triggering ext.flutter.restart...');
          await vmService!.callServiceExtension(
            'ext.flutter.restart',
            isolateId: isolateId!,
          );
        } else {
          stderr.writeln(
              '[mcp:hot_restart] ext.flutter.restart not found, falling back to reassemble...');
          await vmService!.callServiceExtension(
            'ext.flutter.reassemble',
            isolateId: isolateId!,
          );
        }
      }
    }

    // Wait briefly for the isolate to restart before querying the VM
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // Refresh the isolate ID and cache after the restart
    final vm = await vmService!.getVM();
    final isolates = vm.isolates ?? [];
    if (isolates.isNotEmpty) {
      final newId = isolates.first.id;
      if (newId != null) {
        isolateId = newId;
        cachedLibraryId = null;
        stderr
            .writeln('[mcp:hot_restart] Refreshed main isolate ID: $isolateId');
      }
    }

    return CallToolResult(content: [
      TextContent(
        text: 'Hot restart triggered successfully.\n'
            'Isolate reference has been updated. Note: To load new code changes from disk, '
            'save the files in your editor (VS Code, IntelliJ) to let the compiler build them first.',
      )
    ]);
  }

  /// Handles the get_cpu_profile tool request.
  Future<CallToolResult> _handleGetCpuProfile(CallToolRequest req) async {
    final duration = (req.arg<num>('duration_seconds'))?.toInt() ?? 3;
    stderr.writeln(
        '[mcp:cpu_profile] Starting CPU profile, duration=${duration}s');

    await vmService!.clearCpuSamples(isolateId!);
    await Future<void>.delayed(Duration(seconds: duration));

    final endTime = DateTime.now().microsecondsSinceEpoch;
    final cpuSamples = await vmService!.getCpuSamples(isolateId!, 0, endTime);
    final functions = cpuSamples.functions ?? [];

    final hotspots = <Map<String, dynamic>>[];
    final mdBuffer =
        StringBuffer('CPU Execution Hotspots (Exclusive Ticks)\n\n');

    for (final dynamic f in functions) {
      if (f is ProfileFunction) {
        final exclusive = f.exclusiveTicks ?? 0;
        final inclusive = f.inclusiveTicks ?? 0;
        if (exclusive > 0 || inclusive > 0) {
          final func = f.function;
          final String name;
          if (func is FuncRef) {
            name = func.name ?? 'unknown';
          } else {
            name = func?.toString() ?? 'unknown';
          }

          final url = f.resolvedUrl ?? '';
          final resolvedPath = pathResolver != null
              ? await pathResolver!.resolveToAbsolutePath(url)
              : url;

          hotspots.add({
            'name': name,
            'exclusive_ticks': exclusive,
            'inclusive_ticks': inclusive,
            'location': resolvedPath,
          });
        }
      }
    }

    hotspots.sort((a, b) =>
        (b['exclusive_ticks'] as int).compareTo(a['exclusive_ticks'] as int));
    stderr.writeln(
        '[mcp:cpu_profile] Collected ${cpuSamples.sampleCount} samples, ${hotspots.length} active functions');

    final limit = (req.arg<num>('limit'))?.toInt() ?? 15;
    if (hotspots.isEmpty) {
      mdBuffer.writeln('No CPU sampling ticks recorded in the window.');
    } else {
      mdBuffer.writeln(
          '| Function | Exclusive Ticks | Inclusive Ticks | Source Location |');
      mdBuffer.writeln('| :--- | :--- | :--- | :--- |');
      for (final h in hotspots.take(limit)) {
        mdBuffer.writeln(
            '| ${h['name']} | ${h['exclusive_ticks']} | ${h['inclusive_ticks']} | `${h['location']}` |');
      }
    }

    return serializeDualFormat(
      title: 'CPU Profiler Diagnostic Report',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'duration_seconds': duration,
        'total_samples': cpuSamples.sampleCount ?? 0,
        'hotspots': hotspots.take(limit).toList(),
      },
    );
  }

  /// Handles the start_profiling tool request.
  Future<CallToolResult> _handleStartProfiling(CallToolRequest req) async {
    if (isProfiling) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'A profiling session is already active. Call the `profiling` tool with action: `stop` first.')
        ],
        isError: true,
      );
    }

    stderr.writeln('[mcp:profiling] Starting performance profiling session...');
    await vmService!.clearVMTimeline();
    await vmService!
        .setVMTimelineFlags(['Embedder', 'Dart', 'GC', 'API', 'Compiler']);

    double fpsVal = 60.0;
    try {
      final fpsResponse = await vmService!.callServiceExtension(
        'ext.flutter.getDisplayRefreshRate',
        isolateId: isolateId,
      );
      fpsVal = (fpsResponse.json?['fps'] as num?)?.toDouble() ?? 60.0;
    } catch (e) {
      stderr.writeln('[mcp:profile] Error getting display refresh rate: $e');
    }

    isProfiling = true;
    profilingStartTime = DateTime.now().millisecondsSinceEpoch;
    targetFps = fpsVal;

    return CallToolResult(
      content: [
        TextContent(
          text:
              'Profiling started. Interact with the app now, then call the `profiling` tool with action: `stop` to get the analysis.',
        )
      ],
    );
  }

  /// Handles the stop_profiling tool request.
  Future<CallToolResult> _handleStopProfiling(CallToolRequest req) async {
    if (!isProfiling) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'No active profiling session. Call the `profiling` tool with action: `start` first.')
        ],
        isError: true,
      );
    }

    stderr.writeln('[mcp:profiling] Stopping performance profiling session...');
    isProfiling = false;
    final startTime = profilingStartTime;
    final durationMs = startTime != null
        ? DateTime.now().millisecondsSinceEpoch - startTime
        : 0;

    Timeline timeline;
    try {
      timeline = await vmService!.getVMTimeline();
    } finally {
      try {
        await vmService!.setVMTimelineFlags([]);
      } catch (e) {
        stderr.writeln('[mcp:profiling] Error resetting timeline flags: $e');
      }
    }
    final events = timeline.traceEvents ?? [];

    final targetFpsVal = targetFps ?? 60.0;
    final targetFrameTimeMs = 1000.0 / targetFpsVal;

    var totalFrames = 0;
    var jankyFrames = 0;
    var maxFrameTimeMs = 0.0;
    final frameDurations = <double>[];

    bool isFrameEvent(String name) {
      final n = name.toLowerCase();
      return switch (n) {
        'frame' ||
        'vsync' ||
        'gpurasterizer::draw' ||
        'rasterizer::dodraw' =>
          true,
        _
            when n.contains('animator') ||
                n.contains('beginframe') ||
                n.contains('pipeline produce') ||
                n.contains('pipeline consume') =>
          true,
        _ => false,
      };
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

      final severity = switch (maxDur) {
        > 100.0 => 'critical',
        > 32.0 => 'high',
        > 16.0 => 'medium',
        _ => 'low',
      };

      cpuHotspots.add({
        'name': name,
        'totalDurationMs': double.parse(totalDur.toStringAsFixed(2)),
        'callCount': durations.length,
        'avgDurationMs': double.parse(avgDur.toStringAsFixed(2)),
        'maxDurationMs': double.parse(maxDur.toStringAsFixed(2)),
        'severity': severity,
      });
    });

    cpuHotspots.sort((a, b) => (b['totalDurationMs'] as double)
        .compareTo(a['totalDurationMs'] as double));

    Map<String, dynamic> analyzePhase(String phaseName, List<String> patterns) {
      final phaseDurations = <double>[];
      for (final event in events) {
        final ph = event.json?['ph'] as String?;
        final dur = event.json?['dur'] as num?;
        final name = event.json?['name'] as String?;
        if (ph == 'X' && dur != null && name != null) {
          final lower = name.toLowerCase();
          if (patterns.any(lower.contains)) {
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

    final buildPhase = analyzePhase('Build',
        ['build', 'widget', 'createelement', 'updatechild', 'performrebuild']);
    final layoutPhase = analyzePhase('Layout',
        ['layout', 'performlayout', 'flushlayout', 'renderflex', 'renderbox']);
    final paintPhase = analyzePhase(
        'Paint', ['paint', 'flushpaint', 'compositeframe', 'rasterizer']);

    final output = [
      'FLUTTER PERFORMANCE ANALYSIS',
      '',
      'SUMMARY',
      'Profiled for ${(durationMs / 1000.0).toStringAsFixed(1)}s, captured $totalFrames frames (${events.length} raw events)',
      'Average frame time: ${avgFrameTime.toStringAsFixed(2)}ms (target: ${targetFrameTimeMs.toStringAsFixed(1)}ms)',
      if (jankyFrames > 0)
        'Warning: $jankyFrames janky frames detected (${jankPct.toStringAsFixed(1)}% of total)'
      else
        'No jank detected - all frames within budget',
      'Worst frame: ${maxFrameTimeMs.toStringAsFixed(2)}ms (${(maxFrameTimeMs / targetFrameTimeMs).toStringAsFixed(1)}x target)',
      '',
      'FRAME ANALYSIS',
      'Total frames: $totalFrames',
      'Average frame time: ${avgFrameTime.toStringAsFixed(2)}ms',
      'P90 frame time: ${p90.toStringAsFixed(2)}ms',
      'P99 frame time: ${p99.toStringAsFixed(2)}ms',
      'Max frame time: ${maxFrameTimeMs.toStringAsFixed(2)}ms',
      'Jank frames: $jankyFrames ($jankPct%)',
      'Target: ${targetFrameTimeMs.toStringAsFixed(1)}ms (${targetFpsVal.round()}fps)',
      '',
      'PHASE BREAKDOWN',
      'Build:  avg ${buildPhase['avgTimeMs']}ms | max ${buildPhase['maxTimeMs']}ms | ${buildPhase['count']} calls',
      'Layout: avg ${layoutPhase['avgTimeMs']}ms | max ${layoutPhase['maxTimeMs']}ms | ${layoutPhase['count']} calls',
      'Paint:  avg ${paintPhase['avgTimeMs']}ms | max ${paintPhase['maxTimeMs']}ms | ${paintPhase['count']} calls',
      '',
    ];

    if (cpuHotspots.isNotEmpty) {
      output.add('CPU HOTSPOTS');
      for (final h in cpuHotspots.take(10)) {
        final severity = h['severity'] as String;
        final severityLabel = severity == 'critical'
            ? '[CRITICAL]'
            : severity == 'high'
                ? '[HIGH]'
                : severity == 'medium'
                    ? '[MEDIUM]'
                    : '[LOW]';
        output.add('$severityLabel ${h['name']}');
        output.add(
            'Total: ${h['totalDurationMs']}ms | Avg: ${h['avgDurationMs']}ms | Max: ${h['maxDurationMs']}ms | Calls: ${h['callCount']}');
      }
      output.add('');
    }

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
    for (final rec in recommendations) {
      output.add('- $rec');
    }

    return serializeDualFormat(
      title: 'Performance Profiling Analysis',
      markdownBody: output.join('\n'),
      structuredData: {
        'profiling_duration_ms': durationMs,
        'frame_analysis': {
          'total_frames': totalFrames,
          'janky_frames': jankyFrames,
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
  }

  /// Handles the profiling composite tool request.
  Future<CallToolResult> _handleProfiling(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    return switch (action) {
      'start' => _handleStartProfiling(req),
      'stop' => _handleStopProfiling(req),
      'get_cpu' => _handleGetCpuProfile(req),
      'diagnose_jank' => _handleDiagnoseJank(req),
      _ => CallToolResult(
          content: [TextContent(text: 'Unknown profiling action: $action')],
          isError: true,
        ),
    };
  }
}
