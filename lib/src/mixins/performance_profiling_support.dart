import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/connection_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/utils/safe_sampling_window.dart';
import 'package:flutter_agent_lens/src/utils/tool_error_handler.dart';
import 'package:vm_service/vm_service.dart';

/// Support mixin providing tools for frame analysis, CPU sampling, and reload/restart execution.
base mixin PerformanceProfilingSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  static const int _kFrameBudgetUs = 16666;

  /// Whether a CPU timeline sampling or profiling session is currently active.
  bool isProfiling = false;

  /// Epoch timestamp (in milliseconds) when the current profiling session began.
  int? profilingStartTime;

  /// The target display refresh rate (FPS) of the connected target device.
  double? targetFps;

  /// Registers performance profiling and lifecycle tools with the MCP server.
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
          required: const ['action'],
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

  /// Cleans up performance profiling state and resets VM timeline flags.
  Future<void> cleanupPerformanceProfiling() async {
    isProfiling = false;
    profilingStartTime = null;
    targetFps = null;
    final service = vmService;
    if (service != null) {
      try {
        await service.setVMTimelineFlags(const <String>[]);
      } on RPCError catch (e) {
        stderr.writeln('[mcp:profiling] RPC error clearing timeline flags: $e');
      } on Exception catch (e) {
        stderr.writeln('[mcp:profiling] Error resetting timeline flags: $e');
      }
    }
  }

  /// Consolidated entry point for performance profiling operations.
  Future<CallToolResult> _handleProfiling(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    try {
      return await switch (action) {
        'start' => _handleStartProfiling(req),
        'stop' => _handleStopProfiling(req),
        'get_cpu' => _handleGetCpuProfile(req),
        'diagnose_jank' => _handleDiagnoseJank(req),
        _ => CallToolResult(
            content: [TextContent(text: 'Unknown profiling action: $action')],
            isError: true,
          ),
      };
    } on Exception catch (error, stack) {
      return handleToolError(error, stack, 'profiling:$action');
    }
  }

  /// Handles the `diagnose_jank` request with shadow bindings and hardened cleanup.
  Future<CallToolResult> _handleDiagnoseJank(CallToolRequest req) async {
    final service = vmService;
    if (service == null) return notConnected();

    final durationSeconds = (req.arg<num>('duration_seconds'))?.toInt() ?? 3;
    stderr.writeln(
      '[mcp:diagnose_jank] Starting jank diagnosis, duration=${durationSeconds}s',
    );

    await service.setVMTimelineFlags(const ['Embedder', 'Dart', 'GC', 'API']);
    await service.clearVMTimeline();

    Timeline timeline;
    late final SamplingResult samplingResult;
    try {
      samplingResult = await safeSamplingWindow(
        vmService: service,
        duration: Duration(seconds: durationSeconds),
      );
      timeline = await service.getVMTimeline();
    } on RPCError catch (e) {
      stderr.writeln('[mcp:diagnose_jank] RPC error retrieving timeline: $e');
      timeline = Timeline(traceEvents: const []);
    } finally {
      try {
        await service.setVMTimelineFlags(const []);
      } on Exception catch (e) {
        stderr
            .writeln('[mcp:diagnose_jank] Failed to reset timeline flags: $e');
      }
    }

    final events = timeline.traceEvents ?? const [];
    final frameEvents = <Map<String, dynamic>>[];
    var jankyFrames = 0;
    var totalFrames = 0;

    for (final event in events) {
      final eventName = event.json?['name'] as String?;
      if (eventName case 'GPURasterizer::Draw' || 'Animator::BeginFrame') {
        totalFrames++;
        final durationUs = (event.json?['dur'] as num?) ?? 0;
        if (durationUs > _kFrameBudgetUs) {
          jankyFrames++;
          frameEvents.add({
            'event': eventName,
            'duration_ms': durationUs / 1000.0,
            'timestamp': event.json?['ts'],
          });
        }
      }
    }

    final jankPercentage =
        totalFrames > 0 ? (jankyFrames / totalFrames) * 100 : 0.0;
    final mdBuffer = StringBuffer();

    writeSamplingWarningIfInterrupted(
      samplingResult,
      mdBuffer,
      requestedSeconds: durationSeconds,
      dataName: 'timeline events',
    );

    mdBuffer
      ..writeln('### Jank Diagnostic Report\n')
      ..writeln('- **Total Frame Events Sampled:** $totalFrames')
      ..writeln(
        '- **Janky Frame Events (> 16.6ms):** $jankyFrames (${jankPercentage.toStringAsFixed(1)}%)\n',
      );

    final limit = (req.arg<num>('limit'))?.toInt() ?? 15;
    if (jankyFrames > 0) {
      mdBuffer
        ..writeln('| Event | Duration (ms) | Severity |')
        ..writeln('| :--- | :--- | :--- |');
      for (final f in frameEvents.take(limit)) {
        final dur = f['duration_ms'] as double;
        final severity = dur > 33.3 ? 'CRITICAL (>33ms)' : 'WARNING (>16ms)';
        mdBuffer.writeln(
          '| ${f['event']} | ${dur.toStringAsFixed(2)} | $severity |',
        );
      }
    } else {
      mdBuffer.writeln(
        '✨ **Clean Render Cycle:** No frame events exceeded the 16.6ms budget.',
      );
    }

    return serializeDualFormat(
      title: 'Jank Diagnosis',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'total_frames': totalFrames,
        'janky_frames': jankyFrames,
        'jank_percentage': jankPercentage,
        'critical_events': frameEvents.take(50).toList(),
      },
    );
  }

  /// Handles triggering hot reload via DTD with graceful fallback to VM Service.
  Future<CallToolResult> handleHotReload(CallToolRequest req) async {
    final service = vmService;
    final currentIsolateId = isolateId;
    if (service == null || currentIsolateId == null) return notConnected();

    var dtdSuccess = false;
    if (this case final ConnectionSupport dtd
        when dtd.dtdClient != null && vmServiceUri != null) {
      stderr.writeln(
        '[mcp:hot_reload] Triggering ConnectedApp.hotReload via DTD...',
      );
      try {
        await dtd.dtdClient!.call(
          'ConnectedApp',
          'hotReload',
          params: {'vmServiceUri': vmServiceUri},
        );
        dtdSuccess = true;
      } on Exception catch (e) {
        stderr.writeln(
          '[mcp:hot_reload] DTD call failed: $e. Falling back to direct VM Service...',
        );
      }
    }

    if (!dtdSuccess) {
      final reloadMethod = registeredMethodsForService['reloadSources'] ??
          registeredMethodsForService['hotReload'];
      if (reloadMethod != null) {
        stderr.writeln(
          '[mcp:hot_reload] Triggering registered service $reloadMethod...',
        );
        await service.callMethod(
          reloadMethod,
          args: {'isolateId': currentIsolateId},
        );
      } else {
        stderr.writeln('[mcp:hot_reload] Triggering ext.flutter.reassemble...');
        await service.callServiceExtension(
          'ext.flutter.reassemble',
          isolateId: currentIsolateId,
        );
      }
    }

    return CallToolResult(
      content: [
        TextContent(
          text: 'Hot reload triggered successfully.\n'
              'UI has been reassembled. Note: Save modified files in your IDE to ensure changes are compiled.',
        ),
      ],
    );
  }

  /// Handles triggering hot restart with isolate validation.
  Future<CallToolResult> handleHotRestart(CallToolRequest req) async {
    final service = vmService;
    final currentIsolateId = isolateId;
    if (service == null || currentIsolateId == null) return notConnected();

    var dtdSuccess = false;
    if (this case final ConnectionSupport dtd
        when dtd.dtdClient != null && vmServiceUri != null) {
      stderr.writeln(
        '[mcp:hot_restart] Triggering ConnectedApp.hotRestart via DTD...',
      );
      try {
        await dtd.dtdClient!.call(
          'ConnectedApp',
          'hotRestart',
          params: {'vmServiceUri': vmServiceUri},
        );
        dtdSuccess = true;
      } on Exception catch (e) {
        stderr.writeln(
          '[mcp:hot_restart] DTD call failed: $e. Falling back to direct VM Service...',
        );
      }
    }

    if (!dtdSuccess) {
      final hotRestartMethod = registeredMethodsForService['hotRestart'] ??
          registeredMethodsForService['restart'];
      if (hotRestartMethod != null) {
        stderr.writeln(
          '[mcp:hot_restart] Triggering registered service $hotRestartMethod...',
        );
        await service.callMethod(hotRestartMethod);
      } else {
        final isolate = await service.getIsolate(currentIsolateId);
        final extensions = isolate.extensionRPCs ?? const <String>[];

        if (extensions.contains('ext.flutter.restart')) {
          await service.callServiceExtension(
            'ext.flutter.restart',
            isolateId: currentIsolateId,
          );
        } else {
          await service.callServiceExtension(
            'ext.flutter.reassemble',
            isolateId: currentIsolateId,
          );
        }
      }
    }

    // Await isolate lifecycle reset
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final vm = await service.getVM();
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isNotEmpty) {
      if (isolates.first.id case final newId?) {
        isolateId = newId;
        cachedLibraryId = null;
        stderr.writeln(
          '[mcp:hot_restart] Refreshed main isolate ID: $isolateId',
        );
      }
    }

    return CallToolResult(
      content: [
        TextContent(
          text: 'Hot restart triggered successfully.\n'
              'Isolate reference has been updated. Ensure files are saved in your IDE before testing.',
        ),
      ],
    );
  }

  /// Handles the `get_cpu_profile` tool request.
  Future<CallToolResult> _handleGetCpuProfile(CallToolRequest req) async {
    final service = vmService;
    final currentIsolateId = isolateId;
    if (service == null || currentIsolateId == null) return notConnected();

    final durationSeconds = (req.arg<num>('duration_seconds'))?.toInt() ?? 3;
    await service.clearCpuSamples(currentIsolateId);

    final samplingResult = await safeSamplingWindow(
      vmService: service,
      duration: Duration(seconds: durationSeconds),
    );

    final endTimeUs = DateTime.now().microsecondsSinceEpoch;
    CpuSamples cpuSamples;
    try {
      cpuSamples = await service.getCpuSamples(currentIsolateId, 0, endTimeUs);
    } on RPCError catch (_) {
      cpuSamples = CpuSamples(
        sampleCount: 0,
        samplePeriod: 0,
        maxStackDepth: 0,
      );
    }

    final functions = cpuSamples.functions ?? const <dynamic>[];
    final hotspots = <Map<String, dynamic>>[];
    final mdBuffer = StringBuffer();

    writeSamplingWarningIfInterrupted(
      samplingResult,
      mdBuffer,
      requestedSeconds: durationSeconds,
      dataName: 'CPU samples',
    );
    mdBuffer.writeln('### CPU Execution Hotspots (Exclusive Ticks)\n');

    for (final dynamic f in functions) {
      if (f is ProfileFunction) {
        final exclusive = f.exclusiveTicks ?? 0;
        final inclusive = f.inclusiveTicks ?? 0;
        if (exclusive > 0 || inclusive > 0) {
          final func = f.function;
          final name = switch (func) {
            final FuncRef fr => fr.name ?? 'unknown',
            final Object obj => obj.toString(),
            _ => 'unknown',
          };

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

    hotspots.sort(
      (a, b) =>
          (b['exclusive_ticks'] as int).compareTo(a['exclusive_ticks'] as int),
    );

    final limit = (req.arg<num>('limit'))?.toInt() ?? 15;
    if (hotspots.isEmpty) {
      mdBuffer.writeln('No CPU sampling ticks recorded in the window.');
    } else {
      mdBuffer
        ..writeln(
          '| Function | Exclusive Ticks | Inclusive Ticks | Source Location |',
        )
        ..writeln('| :--- | :--- | :--- | :--- |');
      for (final h in hotspots.take(limit)) {
        mdBuffer.writeln(
          '| `${h['name']}` | ${h['exclusive_ticks']} | ${h['inclusive_ticks']} | `${h['location']}` |',
        );
      }
    }

    return serializeDualFormat(
      title: 'CPU Profiler Diagnostic Report',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'duration_seconds': durationSeconds,
        'total_samples': cpuSamples.sampleCount ?? 0,
        'hotspots': hotspots.take(limit).toList(),
      },
    );
  }

  /// Starts a performance profiling session.
  Future<CallToolResult> _handleStartProfiling(CallToolRequest req) async {
    final service = vmService;
    if (service == null) return notConnected();

    if (isProfiling) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'A profiling session is already active. '
                'Call the `profiling` tool with action: `stop` first.',
          ),
        ],
        isError: true,
      );
    }

    await service.clearVMTimeline();
    await service.setVMTimelineFlags(
      const ['Embedder', 'Dart', 'GC', 'API', 'Compiler'],
    );

    var fpsVal = 60.0;
    try {
      final fpsResponse = await service.callServiceExtension(
        'ext.flutter.getDisplayRefreshRate',
        isolateId: isolateId,
      );
      fpsVal = (fpsResponse.json?['fps'] as num?)?.toDouble() ?? 60.0;
    } on Exception catch (e) {
      stderr.writeln('[mcp:profile] Error getting refresh rate: $e');
    }

    isProfiling = true;
    profilingStartTime = DateTime.now().millisecondsSinceEpoch;
    targetFps = fpsVal;

    return CallToolResult(
      content: [
        TextContent(
          text: 'Profiling started. Interact with the app now, '
              'then call the `profiling` tool with action: `stop` to get the report.',
        ),
      ],
    );
  }

  /// Stops an active performance profiling session and outputs aggregate metrics.
  Future<CallToolResult> _handleStopProfiling(CallToolRequest req) async {
    final service = vmService;
    if (service == null) return notConnected();

    if (!isProfiling) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'No active profiling session. '
                'Call the `profiling` tool with action: `start` first.',
          ),
        ],
        isError: true,
      );
    }

    isProfiling = false;
    final startTime = profilingStartTime;
    final durationMs = startTime != null
        ? DateTime.now().millisecondsSinceEpoch - startTime
        : 0;

    Timeline timeline;
    try {
      timeline = await service.getVMTimeline();
    } finally {
      try {
        await service.setVMTimelineFlags(const []);
      } on Exception catch (e) {
        stderr.writeln('[mcp:profiling] Error clearing timeline flags: $e');
      }
    }

    final events = timeline.traceEvents ?? const [];
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

    final buildPhase = analyzePhase('Build', [
      'build',
      'widget',
      'createelement',
      'updatechild',
      'performrebuild',
    ]);
    final layoutPhase = analyzePhase('Layout', [
      'layout',
      'performlayout',
      'flushlayout',
      'renderflex',
      'renderbox',
    ]);
    final paintPhase = analyzePhase(
      'Paint',
      ['paint', 'flushpaint', 'compositeframe', 'rasterizer'],
    );

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
          'Total: ${h['totalDurationMs']}ms | Avg: ${h['avgDurationMs']}ms | Max: ${h['maxDurationMs']}ms | Calls: ${h['callCount']}',
        );
      }
      output.add('');
    }

    final recommendations = <String>[];
    if (events.isEmpty) {
      recommendations.add(
        'No timeline events were captured. Make sure to interact with the app.',
      );
    } else {
      if (jankPct > 10.0) {
        recommendations.add(
          'Significant jank detected. Profile in release/profile mode to get accurate numbers.',
        );
      }
      if ((buildPhase['maxTimeMs'] as double) > 16.0) {
        recommendations.add(
          'Build phase exceeds frame budget. Use const constructors and break up large widget trees.',
        );
      }
      if ((buildPhase['count'] as int) > totalFrames * 3) {
        recommendations.add(
          'Excessive widget rebuilds detected. Wrap in const constructors or use context.select().',
        );
      }
      if ((layoutPhase['maxTimeMs'] as double) > 16.0) {
        recommendations.add(
          'Layout phase is slow. Look for intrinsic dimensions or deeply nested flex layouts.',
        );
      }
      if ((paintPhase['maxTimeMs'] as double) > 16.0) {
        recommendations.add(
          'Paint phase is slow. Use RepaintBoundary to isolate repainting of heavy animated components.',
        );
      }
      for (final h
          in cpuHotspots.where((h) => h['severity'] == 'critical').take(3)) {
        recommendations.add(
          'Critical hotspot: "${h['name']}" taking ${h['maxDurationMs']}ms.',
        );
      }
    }
    if (recommendations.isEmpty) {
      recommendations.add(
        'Performance looks good! No major issues detected in this session.',
      );
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
        'cpu_hotspots': cpuHotspots.take(20).toList(),
        'recommendations': recommendations,
      },
    );
  }
}
