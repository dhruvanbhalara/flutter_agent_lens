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
  });
}
