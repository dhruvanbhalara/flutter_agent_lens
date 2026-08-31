/// Modes for pausing the execution on exceptions.
enum ExceptionPauseMode {
  /// Do not pause on any exceptions.
  none('None'),

  /// Pause on all exceptions.
  all('All'),

  /// Pause only on unhandled exceptions.
  unhandled('Unhandled');

  const ExceptionPauseMode(this.value);

  /// The raw String identifier used by the Dart VM Service.
  final String value;

  /// Resolves the enum from a raw string input, case-insensitively, defaulting to [none] if unresolved.
  static ExceptionPauseMode fromString(String modeStr) {
    final lower = modeStr.toLowerCase();
    for (final e in values) {
      if (e.value.toLowerCase() == lower) return e;
    }
    return ExceptionPauseMode.none;
  }
}
