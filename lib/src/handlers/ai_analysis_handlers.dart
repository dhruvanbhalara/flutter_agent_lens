part of '../../flutter_agent_lens.dart';

/// MCP tool handlers that synthesize higher-level, AI-friendly explanations
/// on top of the raw profiling primitives (jank breakdown, memory patterns).
extension AiAnalysisHandlers on FlutterAgentLensServer {
  /// Collects frame timings over a window and synthesizes a human-readable
  /// explanation of *why* the app is janking — distinguishing UI/build
  /// bottlenecks (Dart work) from raster/GPU bottlenecks.
  Future<CallToolResult> _handleAnalyzeJankCauses(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final duration = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;
    final targetFps = (req.arguments?['target_fps'] as num?)?.toInt() ?? 60;

    stderr.writeln(
        '[mcp:analyze_jank_causes] Collecting frame timings, duration=${duration}s, targetFps=$targetFps');

    try {
      final analyzer = JankAnalyzer();
      final frames = await analyzer.collectFromFrameTimings(
        _vmService!,
        _isolateId!,
        Duration(seconds: duration),
      );

      if (frames.isEmpty) {
        const advice =
            'No frames were captured. The app may be idle — interact with it '
            '(scroll, navigate, animate) during the sampling window, or run in '
            'profile mode for raster timings.';
        return _serializeDualFormat(
          title: '### Jank Cause Analysis',
          markdownBody: advice,
          structuredData: {
            'duration_seconds': duration,
            'target_fps': targetFps,
            'frames_captured': 0,
            'verdict': 'no_data',
          },
        );
      }

      final budgetMicros = 1000000 ~/ targetFps;
      final janky =
          frames.where((f) => f.isJanky(targetFps: targetFps)).toList();

      // Classify each janky frame by its dominant cost.
      final uiBound =
          janky.where((f) => f.uiDurationMicros > budgetMicros).toList();
      final rasterBound = janky
          .where((f) =>
              f.rasterDurationMicros > budgetMicros &&
              f.uiDurationMicros <= budgetMicros)
          .toList();
      final mixed = janky
          .where((f) =>
              f.uiDurationMicros > budgetMicros &&
              f.rasterDurationMicros > budgetMicros)
          .toList();

      final hasRaster = frames.any((f) => f.rasterDurationMicros > 0);
      final jankyPct = (janky.length / frames.length * 100).toStringAsFixed(1);

      double avg(int Function(FrameData) sel) => frames.isEmpty
          ? 0
          : frames.map(sel).reduce((a, b) => a + b) / frames.length / 1000.0;
      final avgBuildMs = avg((f) => f.uiDurationMicros);
      final avgRasterMs = avg((f) => f.rasterDurationMicros);

      final worst = [...frames]
        ..sort((a, b) => b.workDurationMicros.compareTo(a.workDurationMicros));

      // Determine the primary bottleneck and synthesize a verdict.
      String verdict;
      final causes = <String>[];
      if (janky.isEmpty) {
        verdict = 'healthy';
        causes.add(
            'Rendering is smooth — no frames exceeded the ${budgetMicros ~/ 1000}ms budget.');
      } else if (uiBound.length >= rasterBound.length) {
        verdict = 'build_bound';
        causes.add(
            'The primary bottleneck is the **UI/build thread (Dart work)**. '
            '${uiBound.length} frame(s) blew the budget in build/layout.');
        causes.add(
            'Likely culprits: expensive `build()` methods rebuilding too often, '
            'synchronous work on the main isolate, large/unbounded layouts, or '
            'heavy computation that should move to an isolate. Use '
            '`get_widget_rebuild_counts` and `get_cpu_profile` to localize it.');
      } else {
        verdict = 'raster_bound';
        causes.add('The primary bottleneck is the **raster/GPU thread**. '
            '${rasterBound.length} frame(s) had cheap build but slow raster.');
        causes.add(
            'Likely culprits: large/unscaled images, expensive clips, opacity '
            'layers, shadows/blurs (BackdropFilter), or saveLayer calls. '
            'Enable `toggle_repaint_rainbow` and check `toggle_oversized_images`.');
      }
      if (mixed.isNotEmpty) {
        causes.add(
            '${mixed.length} frame(s) were over budget on *both* build and '
            'raster — these are the most expensive to fix and worth prioritizing.');
      }
      if (!hasRaster) {
        causes.add(
            'Note: raster timings are unavailable (debug mode). Re-run with '
            '`--profile` for accurate GPU numbers.');
      }

      final md = StringBuffer();
      md.writeln('**Verdict:** `$verdict`');
      md.writeln();
      md.writeln(
          '- Frames sampled: **${frames.length}** | Janky: **${janky.length}** ($jankyPct%)');
      md.writeln(
          '- Avg build: **${avgBuildMs.toStringAsFixed(2)}ms** | Avg raster: '
          '**${avgRasterMs.toStringAsFixed(2)}ms** | Budget: '
          '**${budgetMicros ~/ 1000}ms** @ ${targetFps}fps');
      md.writeln('- Build-bound frames: **${uiBound.length}** | Raster-bound: '
          '**${rasterBound.length}** | Both: **${mixed.length}**');
      md.writeln();
      md.writeln('#### Explanation');
      for (final c in causes) {
        md.writeln('- $c');
      }
      md.writeln();
      md.writeln('#### Worst frames');
      md.writeln('| Frame | Build (ms) | Raster (ms) | Work (ms) |');
      md.writeln('| :--- | :--- | :--- | :--- |');
      for (final f in worst.take(5)) {
        md.writeln(
            '| ${f.frameNumber} | ${(f.uiDurationMicros / 1000).toStringAsFixed(2)} '
            '| ${(f.rasterDurationMicros / 1000).toStringAsFixed(2)} '
            '| ${(f.workDurationMicros / 1000).toStringAsFixed(2)} |');
      }

      return _serializeDualFormat(
        title: '### Jank Cause Analysis',
        markdownBody: md.toString(),
        structuredData: {
          'duration_seconds': duration,
          'target_fps': targetFps,
          'budget_micros': budgetMicros,
          'frames_captured': frames.length,
          'janky_frames': janky.length,
          'janky_percentage': double.parse(jankyPct),
          'build_bound_frames': uiBound.length,
          'raster_bound_frames': rasterBound.length,
          'mixed_frames': mixed.length,
          'avg_build_ms': avgBuildMs,
          'avg_raster_ms': avgRasterMs,
          'has_raster_data': hasRaster,
          'verdict': verdict,
          'worst_frames': worst
              .take(5)
              .map((f) => {
                    'frame': f.frameNumber,
                    'build_ms': f.uiDurationMicros / 1000.0,
                    'raster_ms': f.rasterDurationMicros / 1000.0,
                    'work_ms': f.workDurationMicros / 1000.0,
                  })
              .toList(),
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:analyze_jank_causes] ERROR: $e');
      stderr.writeln('[mcp:analyze_jank_causes] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Jank cause analysis failed: $e')],
        isError: true,
      );
    }
  }

  /// Reads the current heap/external memory usage plus the heaviest classes
  /// and synthesizes a memory breakdown with actionable recommendations.
  Future<CallToolResult> _handleExplainMemoryBreakdown(
      CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final forceGc = req.arguments?['force_gc'] as bool? ?? false;

    stderr.writeln(
        '[mcp:explain_memory_breakdown] Reading allocation profile, forceGc=$forceGc');

    try {
      final profile =
          await _vmService!.getAllocationProfile(_isolateId!, gc: forceGc);
      final usage = profile.memoryUsage;

      final heapUsage = usage?.heapUsage ?? 0;
      final heapCapacity = usage?.heapCapacity ?? 0;
      final external = usage?.externalUsage ?? 0;
      final totalDart = heapUsage + external;

      String mb(num bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

      // Rank classes by retained bytes.
      final members = (profile.members ?? [])
          .where((m) => m.classRef?.name != null && (m.bytesCurrent ?? 0) > 0)
          .toList()
        ..sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));

      final topClasses = <Map<String, dynamic>>[];
      for (final m in members.take(20)) {
        topClasses.add({
          'class': m.classRef!.name,
          'instances': m.instancesCurrent ?? 0,
          'bytes': m.bytesCurrent ?? 0,
        });
      }

      // Heuristic recommendations based on observed patterns.
      final recommendations = <String>[];
      final fragmentation =
          heapCapacity > 0 ? (heapCapacity - heapUsage) / heapCapacity : 0.0;

      if (external > heapUsage && external > 0) {
        recommendations.add(
            'External memory (${mb(external)}) exceeds Dart heap usage '
            '(${mb(heapUsage)}). This is typically decoded images, native '
            'buffers, or platform resources — audit `Image`/`ui.Image` cache '
            'sizing and dispose native handles.');
      }
      if (fragmentation > 0.4 && heapCapacity > 0) {
        recommendations.add(
            'Heap is ${(fragmentation * 100).toStringAsFixed(0)}% slack '
            '(${mb(heapCapacity)} capacity vs ${mb(heapUsage)} live). High '
            'slack after a spike suggests transient allocations — consider '
            '`force_gc` then re-check, and look for short-lived large buffers.');
      }
      for (final c in members.take(5)) {
        final name = c.classRef!.name ?? '';
        final bytes = c.bytesCurrent ?? 0;
        if ((name.contains('Image') || name.contains('Uint8List')) &&
            bytes > 1024 * 1024) {
          recommendations.add(
              '`$name` retains ${mb(bytes)} across ${c.instancesCurrent} '
              'instances — a common source of image-cache bloat. Cap '
              '`ImageCache.maximumSizeBytes` or resize images at decode time.');
        }
      }
      if (recommendations.isEmpty) {
        recommendations
            .add('No obvious red flags. Heap is ${mb(heapUsage)} live of '
                '${mb(heapCapacity)}. Use `diff_heap_allocations` around a '
                'suspected action to catch growth over time.');
      }

      final md = StringBuffer();
      md.writeln('#### Totals');
      md.writeln('- Dart heap (live): **${mb(heapUsage)}**');
      md.writeln('- Dart heap (capacity): **${mb(heapCapacity)}**');
      md.writeln('- External (native/images): **${mb(external)}**');
      md.writeln('- Total Dart-attributed: **${mb(totalDart)}**');
      if (heapCapacity > 0) {
        md.writeln(
            '- Heap slack: **${(fragmentation * 100).toStringAsFixed(0)}%**');
      }
      md.writeln();
      md.writeln('#### Heaviest classes');
      if (topClasses.isEmpty) {
        md.writeln('No class allocation data available.');
      } else {
        md.writeln('| Class | Instances | Retained |');
        md.writeln('| :--- | :--- | :--- |');
        for (final c in topClasses.take(10)) {
          md.writeln(
              '| `${c['class']}` | ${c['instances']} | ${mb(c['bytes'] as int)} |');
        }
      }
      md.writeln();
      md.writeln('#### Recommendations');
      for (final r in recommendations) {
        md.writeln('- $r');
      }

      return _serializeDualFormat(
        title: '### Memory Breakdown Analysis',
        markdownBody: md.toString(),
        structuredData: {
          'force_gc': forceGc,
          'heap_usage_bytes': heapUsage,
          'heap_capacity_bytes': heapCapacity,
          'external_usage_bytes': external,
          'total_dart_bytes': totalDart,
          'heap_slack_ratio': fragmentation,
          'top_classes': topClasses,
          'recommendations': recommendations,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:explain_memory_breakdown] ERROR: $e');
      stderr.writeln('[mcp:explain_memory_breakdown] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Memory breakdown analysis failed: $e')],
        isError: true,
      );
    }
  }
}
