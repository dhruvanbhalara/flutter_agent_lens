/// Represents the allocations and byte counts of a single Dart/Flutter class.
final class ClassAllocation {
  /// The fully-qualified name of the class.
  final String name;

  /// Total number of active instances of this class on the heap.
  final int instances;

  /// Total number of bytes allocated to instances of this class.
  final int bytes;

  /// Creates a new [ClassAllocation] data container.
  const ClassAllocation({
    required this.name,
    required this.instances,
    required this.bytes,
  });

  /// Factory constructor to parse a [ClassAllocation] from a Map.
  factory ClassAllocation.fromMap(Map<String, dynamic> map) {
    return ClassAllocation(
      name: map['name'] as String? ?? '',
      instances: (map['instances'] as num?)?.toInt() ?? 0,
      bytes: (map['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// Serializes class allocation details into a key-value Map.
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'instances': instances,
      'bytes': bytes,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ClassAllocation &&
        other.name == name &&
        other.instances == instances &&
        other.bytes == bytes;
  }

  @override
  int get hashCode => Object.hash(name, instances, bytes);
}

/// Represents a captured heap allocation state at a point in time.
final class MemorySnapshot {
  /// Descriptive name of the snapshot.
  final String name;

  /// Millisecond timestamp when the snapshot was taken.
  final int timestamp;

  /// Total active heap memory usage in bytes.
  final int heapUsage;

  /// Total capacity of the heap in bytes.
  final int heapCapacity;

  /// Total memory usage external to the Dart heap in bytes.
  final int externalUsage;

  /// Allocation stats for the top classes by byte size.
  final List<ClassAllocation> topClasses;

  /// Creates a new [MemorySnapshot] container.
  const MemorySnapshot({
    required this.name,
    required this.timestamp,
    required this.heapUsage,
    required this.heapCapacity,
    required this.externalUsage,
    required this.topClasses,
  });

  /// Factory constructor to parse a [MemorySnapshot] from a Map.
  factory MemorySnapshot.fromMap(Map<String, dynamic> map) {
    final topClassesList = map['topClasses'] as List<dynamic>? ?? const [];
    return MemorySnapshot(
      name: map['name'] as String? ?? '',
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      heapUsage: (map['heapUsage'] as num?)?.toInt() ?? 0,
      heapCapacity: (map['heapCapacity'] as num?)?.toInt() ?? 0,
      externalUsage: (map['externalUsage'] as num?)?.toInt() ?? 0,
      topClasses: topClassesList
          .map((c) => ClassAllocation.fromMap(c as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Serializes the memory snapshot details into a nested Map.
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'timestamp': timestamp,
      'heapUsage': heapUsage,
      'heapCapacity': heapCapacity,
      'externalUsage': externalUsage,
      'topClasses': topClasses.map((c) => c.toMap()).toList(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MemorySnapshot &&
        other.name == name &&
        other.timestamp == timestamp &&
        other.heapUsage == heapUsage &&
        other.heapCapacity == heapCapacity &&
        other.externalUsage == externalUsage &&
        _listEquals(other.topClasses, topClasses);
  }

  @override
  int get hashCode => Object.hash(
        name,
        timestamp,
        heapUsage,
        heapCapacity,
        externalUsage,
        Object.hashAll(topClasses),
      );

  static bool _listEquals(List<ClassAllocation> a, List<ClassAllocation> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
