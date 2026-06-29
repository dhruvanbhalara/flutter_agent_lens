/// Represents the allocations and byte counts of a single Dart/Flutter class.
final class ClassAllocation {
  /// The fully-qualified name of the class.
  final String name;

  /// Total number of bytes allocated to instances of this class.
  final int bytes;

  /// Total number of active instances of this class on the heap.
  final int instances;

  /// Creates a new [ClassAllocation] data container.
  ClassAllocation({
    required this.name,
    required this.bytes,
    required this.instances,
  });

  /// Serializes class allocation details into a key-value Map.
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'bytes': bytes,
      'instances': instances,
    };
  }
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
  MemorySnapshot({
    required this.name,
    required this.timestamp,
    required this.heapUsage,
    required this.heapCapacity,
    required this.externalUsage,
    required this.topClasses,
  });

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
}
