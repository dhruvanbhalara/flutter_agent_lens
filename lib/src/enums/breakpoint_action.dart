import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the breakpoint tool.
enum BreakpointAction implements ActionEnum {
  /// Add a new breakpoint at a specific line in a file.
  add('add'),

  /// Remove an existing breakpoint by ID.
  remove('remove');

  const BreakpointAction(this.value);

  @override
  final String value;

  static final Map<String, BreakpointAction> _lookup = {
    for (final e in BreakpointAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static BreakpointAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
