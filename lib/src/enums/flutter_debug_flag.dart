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

  /// Resolves the debug flag from the tool parameter name input, defaulting to [debugPaint].
  static FlutterDebugFlag fromString(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('paintbaselines'))
      return FlutterDebugFlag.debugPaintBaselines;
    if (lower.contains('rainbow')) return FlutterDebugFlag.repaintRainbow;
    if (lower.contains('oversized'))
      return FlutterDebugFlag.invertOversizedImages;
    if (lower.contains('dilation')) return FlutterDebugFlag.timeDilation;
    return FlutterDebugFlag.debugPaint;
  }
}
