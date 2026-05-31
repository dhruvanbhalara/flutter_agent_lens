part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for advanced memory diagnostics: GC pressure monitoring,
/// memory timelines, and forced garbage collection.
extension AdvancedMemoryHandlers on FlutterAgentLensServer {
  /// Watches the GC timeline stream over a window and reports collection
  /// frequency, total pause time, and the resulting memory pressure.
  Future<CallToolResult> _handleWatchGcPressure(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final duration = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;

    stderr.writeln(
        '[mcp:watch_gc_pressure] Monitoring GC events, duration=${duration}s');

    try {
      final before = await _vmService!.getMemoryUsage(_isolateId!);

      // Record only the GC stream so the timeline isn't flooded with frames.
      await _vmService!.setVMTimelineFlags(['GC']);
      await _vmService!.clearVMTimeline();

      await Future.delayed(Duration(seconds: duration));

      final timeline = await _vmService!.getVMTimeline();
      final after = await _vmService!.getMemoryUsage(_isolateId!);

      final events = timeline.traceEvents ?? [];
      var gcCount = 0;
      var totalGcMicros = 0;
      var maxGcMicros = 0;
      final gcEvents = <Map<String, dynamic>>[];

      for (final event in events) {
        final name = event.json?['name'] as String? ?? '';
        final cat = event.json?['cat'] as String? ?? '';
        // GC duration events surface on the GC category as complete ('X')
        // events with a 'dur' field (microseconds).
        final isGc = cat == 'GC' ||
            name.contains('CollectNewGeneration') ||
            name.contains('CollectOldGeneration') ||
            name.contains('Scavenge') ||
            name.contains('MarkSweep') ||
            name.contains('StartConcurrentMark');
        final dur = (event.json?['dur'] as num?)?.toInt() ?? 0;
        if (isGc && dur > 0) {
          gcCount++;
          totalGcMicros += dur;
          if (dur > maxGcMicros) maxGcMicros = dur;
          if (gcEvents.length < 20) {
            gcEvents.add({
              'name': name.isEmpty ? 'GC' : name,
              'duration_ms': dur / 1000.0,
              'timestamp': event.json?['ts'],
            });
          }
        }
      }

      final gcPerSec = duration > 0 ? gcCount / duration : 0.0;
      final totalGcMs = totalGcMicros / 1000.0;
      final maxGcMs = maxGcMicros / 1000.0;
      final pressurePct = duration > 0
          ? (totalGcMicros / (duration * 1000000)) * 100
          : 0.0;

      String mb(num b) => '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

      String severity;
      if (gcPerSec < 1) {
        severity = 'LOW';
      } else if (gcPerSec < 5) {
        severity = 'MODERATE';
      } else {
        severity = 'HIGH';
      }

      stderr.writeln(
          '[mcp:watch_gc_pressure] $gcCount GCs, total ${totalGcMs.toStringAsFixed(2)}ms, severity=$severity');

      final md = StringBuffer();
      md.writeln('**Pressure:** `$severity`');
      md.writeln();
      md.writeln('- GC events: **$gcCount** over ${duration}s '
          '(**${gcPerSec.toStringAsFixed(2)}/s**)');
      md.writeln(
          '- Total GC pause: **${totalGcMs.toStringAsFixed(2)} ms** '
          '(**${pressurePct.toStringAsFixed(2)}%** of window)');
      md.writeln('- Longest pause: **${maxGcMs.toStringAsFixed(2)} ms**');
      md.writeln(
          '- Heap before/after: **${mb(before.heapUsage ?? 0)}** → '
          '**${mb(after.heapUsage ?? 0)}**');
      if (severity == 'HIGH') {
        md.writeln();
        md.writeln(
            '> High GC frequency indicates churn — short-lived allocations in '
            'hot paths (build methods, per-frame work). Use '
            '`diff_heap_allocations` to find the class that grows each cycle.');
      }
      if (gcEvents.isNotEmpty) {
        md.writeln();
        md.writeln('| GC Event | Duration (ms) |');
        md.writeln('| :--- | :--- |');
        for (final g in gcEvents.take(10)) {
          md.writeln(
              '| ${g['name']} | ${(g['duration_ms'] as double).toStringAsFixed(2)} |');
        }
      }

      return _serializeDualFormat(
        title: '### GC Pressure Report',
        markdownBody: md.toString(),
        structuredData: {
          'duration_seconds': duration,
          'gc_count': gcCount,
          'gc_per_second': gcPerSec,
          'total_gc_pause_ms': totalGcMs,
          'max_gc_pause_ms': maxGcMs,
          'gc_pressure_percentage': pressurePct,
          'severity': severity,
          'heap_before_bytes': before.heapUsage ?? 0,
          'heap_after_bytes': after.heapUsage ?? 0,
          'external_before_bytes': before.externalUsage ?? 0,
          'external_after_bytes': after.externalUsage ?? 0,
          'gc_events': gcEvents,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:watch_gc_pressure] ERROR: $e');
      stderr.writeln('[mcp:watch_gc_pressure] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'GC pressure monitoring failed: $e')],
        isError: true,
      );
    }
  }

  /// Samples heap and external memory usage at a fixed interval over a window,
  /// producing a time series useful for spotting growth or sawtooth patterns.
  Future<CallToolResult> _handleGetMemoryTimeline(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final duration = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 5;
    var samples = (req.arguments?['samples'] as num?)?.toInt() ?? 10;
    if (samples < 2) samples = 2;
    if (samples > 60) samples = 60;

    stderr.writeln(
        '[mcp:get_memory_timeline] Sampling memory, duration=${duration}s, samples=$samples');

    try {
      final intervalMs = (duration * 1000) ~/ samples;
      final series = <Map<String, dynamic>>[];
      final startMs = DateTime.now().millisecondsSinceEpoch;

      for (var i = 0; i < samples; i++) {
        final usage = await _vmService!.getMemoryUsage(_isolateId!);
        series.add({
          'index': i,
          'offset_ms': DateTime.now().millisecondsSinceEpoch - startMs,
          'heap_usage_bytes': usage.heapUsage ?? 0,
          'heap_capacity_bytes': usage.heapCapacity ?? 0,
          'external_bytes': usage.externalUsage ?? 0,
        });
        if (i < samples - 1) {
          await Future.delayed(Duration(milliseconds: intervalMs));
        }
      }

      String mb(num b) => '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

      final firstHeap = series.first['heap_usage_bytes'] as int;
      final lastHeap = series.last['heap_usage_bytes'] as int;
      final heapDelta = lastHeap - firstHeap;
      final peakHeap = series
          .map((s) => s['heap_usage_bytes'] as int)
          .reduce((a, b) => a > b ? a : b);
      final minHeap = series
          .map((s) => s['heap_usage_bytes'] as int)
          .reduce((a, b) => a < b ? a : b);

      String trend;
      if (heapDelta > 2 * 1024 * 1024) {
        trend = 'GROWING';
      } else if (heapDelta < -2 * 1024 * 1024) {
        trend = 'SHRINKING';
      } else {
        trend = 'STABLE';
      }

      final md = StringBuffer();
      md.writeln('**Trend:** `$trend` '
          '(${heapDelta >= 0 ? '+' : ''}${mb(heapDelta)} over ${duration}s)');
      md.writeln();
      md.writeln('- Min heap: **${mb(minHeap)}** | Peak heap: **${mb(peakHeap)}**');
      md.writeln(
          '- Start: **${mb(firstHeap)}** → End: **${mb(lastHeap)}**');
      if (trend == 'GROWING') {
        md.writeln();
        md.writeln(
            '> Monotonic growth across the window can indicate a leak. Run '
            '`watch_gc_pressure` and `diff_heap_allocations` to confirm whether '
            'the growth survives a GC.');
      }
      md.writeln();
      md.writeln('| t (ms) | Heap | Capacity | External |');
      md.writeln('| :--- | :--- | :--- | :--- |');
      for (final s in series) {
        md.writeln('| ${s['offset_ms']} | ${mb(s['heap_usage_bytes'] as int)} '
            '| ${mb(s['heap_capacity_bytes'] as int)} '
            '| ${mb(s['external_bytes'] as int)} |');
      }

      return _serializeDualFormat(
        title: '### Memory Timeline',
        markdownBody: md.toString(),
        structuredData: {
          'duration_seconds': duration,
          'sample_count': series.length,
          'heap_delta_bytes': heapDelta,
          'peak_heap_bytes': peakHeap,
          'min_heap_bytes': minHeap,
          'trend': trend,
          'samples': series,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:get_memory_timeline] ERROR: $e');
      stderr.writeln('[mcp:get_memory_timeline] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Memory timeline sampling failed: $e')],
        isError: true,
      );
    }
  }

  /// Forces a garbage collection and reports how much memory was reclaimed.
  /// The VM exposes manual GC via `getAllocationProfile(gc: true)`.
  Future<CallToolResult> _handleForceGc(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();

    stderr.writeln('[mcp:force_gc] Forcing garbage collection...');

    try {
      final before = await _vmService!.getMemoryUsage(_isolateId!);

      // Triggering an allocation profile with gc: true performs a full GC.
      await _vmService!.getAllocationProfile(_isolateId!, gc: true);

      final after = await _vmService!.getMemoryUsage(_isolateId!);

      final heapBefore = before.heapUsage ?? 0;
      final heapAfter = after.heapUsage ?? 0;
      final reclaimed = heapBefore - heapAfter;

      String mb(num b) => '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

      stderr.writeln(
          '[mcp:force_gc] Reclaimed ${mb(reclaimed)} (${mb(heapBefore)} → ${mb(heapAfter)})');

      final md = StringBuffer();
      md.writeln('Garbage collection triggered successfully.');
      md.writeln();
      md.writeln('- Heap before: **${mb(heapBefore)}**');
      md.writeln('- Heap after: **${mb(heapAfter)}**');
      md.writeln(
          '- Reclaimed: **${reclaimed >= 0 ? '' : ''}${mb(reclaimed)}**');

      return _serializeDualFormat(
        title: '### Forced Garbage Collection',
        markdownBody: md.toString(),
        structuredData: {
          'heap_before_bytes': heapBefore,
          'heap_after_bytes': heapAfter,
          'reclaimed_bytes': reclaimed,
          'external_before_bytes': before.externalUsage ?? 0,
          'external_after_bytes': after.externalUsage ?? 0,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:force_gc] ERROR: $e');
      stderr.writeln('[mcp:force_gc] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Force GC failed: $e')],
        isError: true,
      );
    }
  }
}
