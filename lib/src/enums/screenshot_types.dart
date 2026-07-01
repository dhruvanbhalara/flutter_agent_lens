/// The visual screenshot comparison action.
enum ScreenshotAction {
  /// Capture baseline screenshot.
  captureBaseline('capture_baseline'),

  /// Compare visual screen with baseline screenshot.
  compare('compare');

  /// The raw String identifier of the action.
  final String value;

  const ScreenshotAction(this.value);

  static final Map<String, ScreenshotAction> _lookup = {
    for (final e in ScreenshotAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Throws an [ArgumentError] if the action is unsupported.
  static ScreenshotAction fromString(String val) {
    final match = _lookup[val.toLowerCase()];
    if (match == null) {
      throw ArgumentError('Unsupported action: $val');
    }
    return match;
  }
}

/// The format/method used to capture screenshots.
enum ScreenshotType {
  /// Native device screenshot.
  device('device'),

  /// Skia Picture representation via VM service.
  skia('skia');

  /// The raw String identifier of the screenshot type.
  final String value;

  const ScreenshotType(this.value);

  static final Map<String, ScreenshotType> _lookup = {
    for (final e in ScreenshotType.values) e.value.toLowerCase(): e,
  };

  /// Resolves the type from a raw string, defaulting to [device].
  static ScreenshotType fromString(String? val) {
    if (val == null) return ScreenshotType.device;
    return _lookup[val.toLowerCase()] ?? ScreenshotType.device;
  }
}
