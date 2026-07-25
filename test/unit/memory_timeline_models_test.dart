import 'package:flutter_agent_lens/src/models/memory_models.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryTimelineSample Tests', () {
    test('fromMap and toMap round-trip', () {
      final json = {
        'timestamp': 1717171717,
        'heap_used': 5000000,
        'heap_capacity': 10000000,
        'external_usage': 1000000,
        'rss': 25000000,
        'gc_events_in_interval': 2,
      };

      final sample = MemoryTimelineSample.fromMap(json);
      expect(sample.timestamp, equals(1717171717));
      expect(sample.heapUsed, equals(5000000));
      expect(sample.heapCapacity, equals(10000000));
      expect(sample.externalUsage, equals(1000000));
      expect(sample.rss, equals(25000000));
      expect(sample.gcEventsInInterval, equals(2));

      final mapped = sample.toMap();
      expect(mapped, equals(json));
    });

    test('equality and hashCode', () {
      const sample1 = MemoryTimelineSample(
        timestamp: 1000,
        heapUsed: 500,
        heapCapacity: 1000,
        externalUsage: 100,
        rss: 2000,
        gcEventsInInterval: 1,
      );

      const sample2 = MemoryTimelineSample(
        timestamp: 1000,
        heapUsed: 500,
        heapCapacity: 1000,
        externalUsage: 100,
        rss: 2000,
        gcEventsInInterval: 1,
      );

      const sampleDifferent = MemoryTimelineSample(
        timestamp: 2000,
        heapUsed: 500,
        heapCapacity: 1000,
        externalUsage: 100,
        rss: 2000,
        gcEventsInInterval: 1,
      );

      expect(sample1, equals(sample2));
      expect(sample1.hashCode, equals(sample2.hashCode));
      expect(sample1, isNot(equals(sampleDifferent)));
    });

    test('toString representation', () {
      const sample = MemoryTimelineSample(
        timestamp: 1000,
        heapUsed: 500,
        heapCapacity: 1000,
        externalUsage: 100,
        rss: 2000,
        gcEventsInInterval: 1,
      );
      expect(sample.toString(), contains('1000'));
      expect(sample.toString(), contains('500'));
      expect(sample.toString(), contains('2000'));
    });
  });
}
