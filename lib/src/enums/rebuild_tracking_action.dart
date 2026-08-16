import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the rebuild_tracking tool.
enum RebuildTrackingAction implements ActionEnum {
  /// Start widget rebuild tracking session.
  start('start'),

  /// Stop rebuild tracking and return report.
  stop('stop'),

  /// Get current widget rebuild counts snapshot.
  getCounts('getCounts');

  const RebuildTrackingAction(this.value);

  @override
  final String value;

  static final Map<String, RebuildTrackingAction> _lookup = {
    for (final e in RebuildTrackingAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static RebuildTrackingAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
