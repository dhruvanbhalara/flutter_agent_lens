/// The target mobile operating system platform for deep link validation.
enum TargetPlatform {
  /// Android OS.
  android('android'),

  /// iOS OS.
  ios('ios');

  /// The raw String representation of the platform.
  final String value;

  const TargetPlatform(this.value);

  /// Resolves the enum from a raw string input, case-insensitively.
  /// Throws an [ArgumentError] if the platform is unsupported.
  static TargetPlatform fromString(String val) {
    return TargetPlatform.values.firstWhere(
      (e) => e.value.toLowerCase() == val.toLowerCase(),
      orElse: () => throw ArgumentError('Unsupported platform: $val'),
    );
  }
}
