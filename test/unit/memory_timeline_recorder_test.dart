import 'package:flutter_agent_lens/src/services/memory_timeline_recorder.dart';
import 'package:test/test.dart';

class FakeMemoryStatsProvider implements MemoryStatsProvider {
  int gcAcquiredCount = 0;
  int gcReleasedCount = 0;
  int gcEventCount = 0;

  @override
  int get currentGcEventCount => gcEventCount;

  @override
  Future<void> acquireGcStream() async {
    gcAcquiredCount++;
  }

  @override
  Future<void> releaseGcStream() async {
    gcReleasedCount++;
  }

  @override
  Future<({int heapCapacity, int heapUsage, int externalUsage})>
      getHeapStats() async {
    return (heapUsage: 1000, heapCapacity: 2000, externalUsage: 500);
  }

  @override
  Future<int> getRssBytes() async {
    return 5000;
  }
}

void main() {
  group('MemoryTimelineRecorder Unit Tests', () {
    late FakeMemoryStatsProvider fakeProvider;
    late MemoryTimelineRecorder recorder;

    setUp(() {
      fakeProvider = FakeMemoryStatsProvider();
      recorder = MemoryTimelineRecorder(fakeProvider);
    });

    test('records samples and manages GC stream lifecycle correctly', () async {
      final samples = await recorder.recordTimeline(durationSeconds: 1);

      expect(samples.length, equals(2));
      expect(fakeProvider.gcAcquiredCount, equals(1));
      expect(fakeProvider.gcReleasedCount, equals(1));

      for (final sample in samples) {
        expect(sample.heapUsed, equals(1000));
        expect(sample.heapCapacity, equals(2000));
        expect(sample.externalUsage, equals(500));
        expect(sample.rss, equals(5000));
      }
    });
  });
}
