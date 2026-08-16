import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the widget tool.
enum WidgetAction implements ActionEnum {
  /// Inspect layout details and properties of a specific widget.
  inspect('inspect'),

  /// Toggle on-device widget selection overlay.
  toggleSelection('toggleSelection'),

  /// Retrieve lightweight JSON widget tree representation.
  getTree('getTree');

  const WidgetAction(this.value);

  @override
  final String value;

  static final Map<String, WidgetAction> _lookup = {
    for (final e in WidgetAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static WidgetAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
