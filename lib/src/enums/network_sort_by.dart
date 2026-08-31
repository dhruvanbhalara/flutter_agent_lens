/// Sorting strategies for captured network requests.
enum NetworkSortBy {
  /// Sort requests chronologically by start time.
  time('time'),

  /// Sort requests by request execution duration.
  duration('duration'),

  /// Sort requests by response content size.
  size('size');

  const NetworkSortBy(this.value);

  /// The raw String identifier of the sort strategy.
  final String value;

  /// Resolves the sort enum from a nullable raw string, defaulting to [time].
  static NetworkSortBy fromString(String? val) {
    if (val == null) return NetworkSortBy.time;
    for (final e in values) {
      if (e.value == val) return e;
    }
    return NetworkSortBy.time;
  }
}
