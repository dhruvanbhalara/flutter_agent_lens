import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// The visual screenshot comparison action.
enum ScreenshotAction implements ActionEnum {
  /// Capture an on-demand screenshot.
  take('take'),

  /// Capture baseline screenshot.
  captureBaseline('captureBaseline'),

  /// Compare visual screen with baseline screenshot.
  compare('compare');

  const ScreenshotAction(this.value);

  @override
  final String value;

  static final Map<String, ScreenshotAction> _lookup = {
    for (final e in ScreenshotAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static ScreenshotAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
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

  static final Map<String, ScreenshotType> _lookup = {
    for (final e in ScreenshotType.values) e.value.toLowerCase(): e,
  };

  /// Resolves the type from a raw string, defaulting to [device].
  static ScreenshotType fromString(String? val) {
    if (val == null) return ScreenshotType.device;
    return _lookup[val.toLowerCase()] ?? ScreenshotType.device;
  }
}
