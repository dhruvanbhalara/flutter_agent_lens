/// The visual screenshot comparison action.
enum ScreenshotAction {
  /// Capture baseline screenshot.
  captureBaseline('capture_baseline'),

  /// Compare visual screen with baseline screenshot.
  compare('compare');

  const ScreenshotAction(this.value);

  /// The raw String identifier of the action.
  final String value;

  /// Resolves the action from a raw string.
  /// Throws an [ArgumentError] if the action is unsupported.
  static ScreenshotAction fromString(String val) {
    final lower = val.toLowerCase();
    for (final e in values) {
      if (e.value.toLowerCase() == lower) return e;
    }
    throw ArgumentError('Unsupported action: $val');
  }
}

/// The format/method used to capture screenshots.
enum ScreenshotType {
  /// Native device screenshot.
  device('device'),

  /// Skia Picture representation via VM service.
  skia('skia');

  const ScreenshotType(this.value);

  /// The raw String identifier of the screenshot type.
  final String value;

  /// Resolves the type from a raw string, defaulting to [device].
  static ScreenshotType fromString(String? val) {
    if (val == null) return ScreenshotType.device;
    final lower = val.toLowerCase();
    for (final e in values) {
      if (e.value.toLowerCase() == lower) return e;
    }
    return ScreenshotType.device;
  }
}
