/// Flutter widget inspector/rendering debug flags.
enum FlutterDebugFlag {
  /// Toggle visual debugging layout sizes.
  debugPaint('debugPaintSizeEnabled', 'debugPaint'),

  /// Toggle visual baselines of text widgets.
  debugPaintBaselines(
      'debugPaintBaselinesEnabled', 'debugPaintBaselinesEnabled'),

  /// Force repaint showing visual boundaries.
  repaintRainbow('repaintRainbow', 'repaintRainbow'),

  /// Invert oversized images to help performance optimization.
  invertOversizedImages('invertOversizedImages', 'invertOversizedImages'),

  /// Adjust animation time dilation (slow motion animations).
  timeDilation('timeDilation', 'timeDilation');

  const FlutterDebugFlag(this.flagName, this.extensionSuffix);

  /// The friendly flag name used in tool inputs.
  final String flagName;

  /// The actual suffix of the extension key under `ext.flutter.*`.
  final String extensionSuffix;

  /// Resolves the debug flag from the tool parameter name input.
  /// Returns `null` if the flag is unsupported.
  static FlutterDebugFlag? fromString(String name) =>
      _lookup[name.toLowerCase()];

  static final Map<String, FlutterDebugFlag> _lookup = {
    for (final flag in FlutterDebugFlag.values) ...{
      flag.flagName.toLowerCase(): flag,
      flag.extensionSuffix.toLowerCase(): flag,
    },
    'debugpaint': FlutterDebugFlag.debugPaint,
    'debugpaintbaselines': FlutterDebugFlag.debugPaintBaselines,
    'debugrepaintrainbowenabled': FlutterDebugFlag.repaintRainbow,
    'debuginvertoversizedimages': FlutterDebugFlag.invertOversizedImages,
  };
}
