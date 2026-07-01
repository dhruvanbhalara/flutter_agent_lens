/// The target mobile operating system platform for deep link validation.
enum TargetPlatform {
  /// Android OS.
  android('android'),

  /// iOS OS.
  ios('ios');

  /// The raw String representation of the platform.
  final String value;

  const TargetPlatform(this.value);

  static final Map<String, TargetPlatform> _lookup = {
    for (final e in TargetPlatform.values) e.value.toLowerCase(): e,
  };

  /// Resolves the enum from a raw string input, case-insensitively.
  /// Throws an [ArgumentError] if the platform is unsupported.
  static TargetPlatform fromString(String val) {
    final match = _lookup[val.toLowerCase()];
    if (match == null) {
      throw ArgumentError('Unsupported platform: $val');
    }
    return match;
  }
}
