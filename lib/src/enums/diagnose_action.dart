import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the diagnose_project tool.
enum DiagnoseAction implements ActionEnum {
  /// Analyze build output size and package breakdown.
  bundleSize('bundleSize'),

  /// Validate deep link domain configurations.
  deepLinks('deepLinks');

  const DiagnoseAction(this.value);

  @override
  final String value;

  static final Map<String, DiagnoseAction> _lookup = {
    for (final e in DiagnoseAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static DiagnoseAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
