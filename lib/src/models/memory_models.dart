/// Represents the allocations and byte counts of a single Dart/Flutter class.
final class ClassAllocation {
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

  /// The fully-qualified name of the class.
  final String name;

  /// Total number of active instances of this class on the heap.
  final int instances;

  /// Total number of bytes allocated to instances of this class.
  final int bytes;

  /// Serializes class allocation details into a key-value Map.
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'instances': instances,
      'bytes': bytes,
    };
  }

  @override
  String toString() {
    return 'ClassAllocation(name: $name, instances: $instances, bytes: $bytes)';
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
      topClasses: List.unmodifiable(
        topClassesList
            .whereType<Map<dynamic, dynamic>>()
            .map((c) => ClassAllocation.fromMap(Map<String, dynamic>.from(c))),
      ),
    );
  }

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
  String toString() {
    return 'MemorySnapshot(name: $name, heapUsage: $heapUsage, heapCapacity: $heapCapacity)';
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

/// Represents a single point-in-time memory sample for timeline recording.
final class MemoryTimelineSample {
  /// Creates a new [MemoryTimelineSample] instance.
  const MemoryTimelineSample({
    required this.timestamp,
    required this.heapUsed,
    required this.heapCapacity,
    required this.externalUsage,
    required this.rss,
    required this.gcEventsInInterval,
  });

  /// Factory constructor to parse a [MemoryTimelineSample] from a Map.
  factory MemoryTimelineSample.fromMap(Map<String, dynamic> map) {
    return MemoryTimelineSample(
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
      heapUsed: (map['heapUsed'] as num?)?.toInt() ?? 0,
      heapCapacity: (map['heapCapacity'] as num?)?.toInt() ?? 0,
      externalUsage: (map['externalUsage'] as num?)?.toInt() ?? 0,
      rss: (map['rss'] as num?)?.toInt() ?? 0,
      gcEventsInInterval: (map['gcEventsInInterval'] as num?)?.toInt() ?? 0,
    );
  }

  /// Millisecond timestamp of the sample.
  final int timestamp;

  /// Active heap usage in bytes.
  final int heapUsed;

  /// Total heap capacity in bytes.
  final int heapCapacity;

  /// External memory usage in bytes.
  final int externalUsage;

  /// Resident Set Size (RSS) process memory in bytes.
  final int rss;

  /// Number of GC events recorded since the previous sample.
  final int gcEventsInInterval;

  /// Serializes the timeline sample to a Map.
  Map<String, dynamic> toMap() => {
        'timestamp': timestamp,
        'heapUsed': heapUsed,
        'heapCapacity': heapCapacity,
        'externalUsage': externalUsage,
        'rss': rss,
        'gcEventsInInterval': gcEventsInInterval,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryTimelineSample &&
          timestamp == other.timestamp &&
          heapUsed == other.heapUsed &&
          heapCapacity == other.heapCapacity &&
          externalUsage == other.externalUsage &&
          rss == other.rss &&
          gcEventsInInterval == other.gcEventsInInterval;

  @override
  int get hashCode => Object.hash(
        timestamp,
        heapUsed,
        heapCapacity,
        externalUsage,
        rss,
        gcEventsInInterval,
      );

  @override
  String toString() =>
      'MemoryTimelineSample(ts: $timestamp, heap: $heapUsed, rss: $rss)';
}
