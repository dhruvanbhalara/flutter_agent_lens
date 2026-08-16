import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the profiling tool.
enum ProfilingAction implements ActionEnum {
  /// Start CPU profiling session.
  start('start'),

  /// Stop CPU profiling session and return report.
  stop('stop'),

  /// Get CPU sample hotspots.
  getCpu('getCpu'),

  /// Diagnose frame rendering jank and timing.
  diagnoseJank('diagnoseJank');

  const ProfilingAction(this.value);

  @override
  final String value;

  static final Map<String, ProfilingAction> _lookup = {
    for (final e in ProfilingAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static ProfilingAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
