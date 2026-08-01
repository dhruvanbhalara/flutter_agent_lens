import 'package:flutter_agent_lens/src/models/memory_models.dart';
import 'package:test/test.dart';

void main() {
  group('ClassAllocation Tests', () {
    test('fromMap and toMap round-trip', () {
      final json = {
        'name': 'MyWidget',
        'bytes': 1024,
        'instances': 42,
      };

      final alloc = ClassAllocation.fromMap(json);
      expect(alloc.name, equals('MyWidget'));
      expect(alloc.bytes, equals(1024));
      expect(alloc.instances, equals(42));

      final mapped = alloc.toMap();
      expect(mapped, equals(json));
    });

    test('equality and hashCode', () {
      const alloc1 = ClassAllocation(
        name: 'MyWidget',
        bytes: 1024,
        instances: 42,
      );

      const alloc2 = ClassAllocation(
        name: 'MyWidget',
        bytes: 1024,
        instances: 42,
      );

      const allocDifferent = ClassAllocation(
        name: 'Different',
        bytes: 100,
        instances: 1,
      );

      expect(alloc1, equals(alloc2));
      expect(alloc1.hashCode, equals(alloc2.hashCode));
      expect(alloc1, isNot(equals(allocDifferent)));
    });

    test('toString representation', () {
      const alloc = ClassAllocation(
        name: 'MyWidget',
        bytes: 1024,
        instances: 42,
      );
      expect(alloc.toString(), contains('MyWidget'));
      expect(alloc.toString(), contains('42'));
    });
  });

  group('MemorySnapshot Tests', () {
    test('fromMap and toMap round-trip', () {
      final json = {
        'name': 'baseline',
        'timestamp': 1717171717,
        'heapUsage': 5000000,
        'heapCapacity': 10000000,
        'externalUsage': 1000000,
        'topClasses': [
          {
            'name': 'MyWidget',
            'bytes': 1024,
            'instances': 42,
          }
        ],
      };

      final snapshot = MemorySnapshot.fromMap(json);
      expect(snapshot.name, equals('baseline'));
      expect(snapshot.timestamp, equals(1717171717));
      expect(snapshot.heapUsage, equals(5000000));
      expect(snapshot.topClasses.length, equals(1));
      expect(snapshot.topClasses.first.name, equals('MyWidget'));

      final mapped = snapshot.toMap();
      expect(mapped, equals(json));
    });

    test('equality and hashCode', () {
      const alloc1 = ClassAllocation(
        name: 'MyWidget',
        bytes: 1024,
        instances: 42,
      );

      const snapshot1 = MemorySnapshot(
        name: 'baseline',
        timestamp: 12345,
        heapUsage: 100,
        heapCapacity: 200,
        externalUsage: 50,
        topClasses: [alloc1],
      );

      const snapshot2 = MemorySnapshot(
        name: 'baseline',
        timestamp: 12345,
        heapUsage: 100,
        heapCapacity: 200,
        externalUsage: 50,
        topClasses: [alloc1],
      );

      const snapshotDifferent = MemorySnapshot(
        name: 'different',
        timestamp: 99999,
        heapUsage: 100,
        heapCapacity: 200,
        externalUsage: 50,
        topClasses: [],
      );

      expect(snapshot1, equals(snapshot2));
      expect(snapshot1.hashCode, equals(snapshot2.hashCode));
      expect(snapshot1, isNot(equals(snapshotDifferent)));
    });

    test('topClasses is unmodifiable', () {
      final json = {
        'name': 'baseline',
        'timestamp': 12345,
        'heapUsage': 100,
        'heapCapacity': 200,
        'externalUsage': 50,
        'topClasses': [
          {
            'name': 'MyWidget',
            'bytes': 1024,
            'instances': 42,
          }
        ],
      };
      final snapshot = MemorySnapshot.fromMap(json);
      expect(
        () => snapshot.topClasses.add(
          const ClassAllocation(name: 'NewWidget', bytes: 10, instances: 1),
        ),
        throwsUnsupportedError,
      );
    });
  });

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
