import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the debug_flag tool.
enum DebugFlagAction implements ActionEnum {
  /// Toggle a specific Flutter debug paint or overlay flag.
  toggle('toggle'),

  /// Toggle visibility of framework/package widgets in inspector.
  togglePackageWidgets('togglePackageWidgets');

  const DebugFlagAction(this.value);

  @override
  final String value;

  static final Map<String, DebugFlagAction> _lookup = {
    for (final e in DebugFlagAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static DebugFlagAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
