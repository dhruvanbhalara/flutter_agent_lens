import 'dart:async';
import 'dart:io';
import 'package:flutter_agent_lens/src/models/memory_models.dart';

/// Abstract interface for fetching heap and process memory stats.
abstract interface class MemoryStatsProvider {
  /// Fetches Dart heap usage, capacity, and external usage.
  Future<({int heapUsage, int heapCapacity, int externalUsage})> getHeapStats();

  /// Fetches total process Resident Set Size (RSS) memory in bytes.
  Future<int> getRssBytes();

  /// Acquires a reference to the active GC event stream.
  Future<void> acquireGcStream();

  /// Releases a reference to the active GC event stream.
  Future<void> releaseGcStream();

  /// Returns the total number of GC events recorded so far.
  int get currentGcEventCount;
}

/// Orchestrates memory timeline recording with drift-compensated sampling.
final class MemoryTimelineRecorder {
  /// Creates a new [MemoryTimelineRecorder] with the given [statsProvider].
  MemoryTimelineRecorder(this.statsProvider);

  /// The underlying memory stats provider.
  final MemoryStatsProvider statsProvider;

  /// Records memory metrics over [durationSeconds] with drift compensation.
  Future<List<MemoryTimelineSample>> recordTimeline({
    required int durationSeconds,
  }) async {
    final clampedDuration = durationSeconds.clamp(1, 60);
    await statsProvider.acquireGcStream();

    try {
      final samples = <MemoryTimelineSample>[];
      var lastGcCount = statsProvider.currentGcEventCount;

      for (var i = 0; i <= clampedDuration; i++) {
        final stopwatch = Stopwatch()..start();

        final results = await Future.wait([
          statsProvider.getHeapStats(),
          statsProvider.getRssBytes(),
        ]);

        final heap = results[0] as ({
          int heapUsage,
          int heapCapacity,
          int externalUsage
        });
        final rss = results[1] as int;
        final currentGcCount = statsProvider.currentGcEventCount;
        final gcInInterval = currentGcCount - lastGcCount;
        lastGcCount = currentGcCount;

        samples.add(MemoryTimelineSample(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          heapUsed: heap.heapUsage,
          heapCapacity: heap.heapCapacity,
          externalUsage: heap.externalUsage,
          rss: rss,
          gcEventsInInterval: gcInInterval,
        ));

        if (i < clampedDuration) {
          stopwatch.stop();
          final elapsed = stopwatch.elapsed;
          final remaining = const Duration(seconds: 1) - elapsed;
          if (remaining > Duration.zero) {
            await Future<void>.delayed(remaining);
          }
        }
      }

      return samples;
    } catch (e, st) {
      stderr.writeln(
          '[MemoryTimelineRecorder] Error recording memory timeline: $e\n$st');
      rethrow;
    } finally {
      await statsProvider.releaseGcStream();
    }
  }
}
