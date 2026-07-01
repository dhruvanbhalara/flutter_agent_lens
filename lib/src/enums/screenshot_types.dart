/// The visual screenshot comparison action.
enum ScreenshotAction {
  /// Capture baseline screenshot.
  captureBaseline('capture_baseline'),

  /// Compare visual screen with baseline screenshot.
  compare('compare');

  /// The raw String identifier of the action.
  final String value;

  const ScreenshotAction(this.value);

  /// Resolves the action from a raw string.
  /// Throws an [ArgumentError] if the action is unsupported.
  static ScreenshotAction fromString(String val) {
    return ScreenshotAction.values.firstWhere(
      (e) => e.value.toLowerCase() == val.toLowerCase(),
      orElse: () => throw ArgumentError('Unsupported action: $val'),
    );
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

  /// Resolves the type from a raw string, defaulting to [device].
  static ScreenshotType fromString(String? val) {
    return ScreenshotType.values.firstWhere(
      (e) => e.value.toLowerCase() == val?.toLowerCase(),
      orElse: () => ScreenshotType.device,
    );
  }
}
