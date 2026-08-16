import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the console_logs tool.
enum ConsoleLogAction implements ActionEnum {
  /// Fetch buffered console log lines.
  fetch('fetch'),

  /// Watch real-time console log stream.
  watch('watch');

  const ConsoleLogAction(this.value);

  @override
  final String value;

  static final Map<String, ConsoleLogAction> _lookup = {
    for (final e in ConsoleLogAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static ConsoleLogAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
