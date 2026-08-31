/// The target mobile operating system platform for deep link validation.
enum TargetPlatform {
  /// Android OS.
  android('android'),

  /// iOS OS.
  ios('ios');

  const TargetPlatform(this.value);

  /// The raw String representation of the platform.
  final String value;

  /// Resolves the enum from a raw string input, case-insensitively.
  /// Throws an [ArgumentError] if the platform is unsupported.
  static TargetPlatform fromString(String val) {
    final lower = val.toLowerCase();
    for (final e in values) {
      if (e.value.toLowerCase() == lower) return e;
    }
    throw ArgumentError('Unsupported platform: $val');
  }
}
