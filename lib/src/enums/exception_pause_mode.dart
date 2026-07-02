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

  static final Map<String, ExceptionPauseMode> _lookup = {
    for (final e in ExceptionPauseMode.values) e.value.toLowerCase(): e,
  };

  /// Resolves the enum from a raw string input, case-insensitively, defaulting to [none] if unresolved.
  static ExceptionPauseMode fromString(String modeStr) {
    return _lookup[modeStr.toLowerCase()] ?? ExceptionPauseMode.none;
  }
}
