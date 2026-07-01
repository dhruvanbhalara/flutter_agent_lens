/// Sorting strategies for captured network requests.
enum NetworkSortBy {
  /// Sort requests chronologically by start time.
  time('time'),

  /// Sort requests by request execution duration.
  duration('duration'),

  /// Sort requests by response content size.
  size('size');

  /// The raw String identifier of the sort strategy.
  final String value;

  const NetworkSortBy(this.value);

  /// Resolves the sort enum from a nullable raw string, defaulting to [time].
  static NetworkSortBy fromString(String? val) {
    return NetworkSortBy.values.firstWhere(
      (e) => e.value == val,
      orElse: () => NetworkSortBy.time,
    );
  }
}
