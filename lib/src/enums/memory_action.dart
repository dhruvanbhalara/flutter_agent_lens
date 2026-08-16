import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the memory tool.
enum MemoryAction implements ActionEnum {
  /// Get current heap snapshot overview.
  getSnapshot('getSnapshot'),

  /// Save current heap snapshot with a name.
  save('save'),

  /// Compare two saved heap snapshots.
  compare('compare'),

  /// List saved heap snapshots.
  list('list'),

  /// Audit class memory leaks and retaining paths.
  auditLeak('auditLeak'),

  /// Diff heap allocation deltas over time.
  diffAllocations('diffAllocations'),

  /// Retrieve referrers of a target object.
  getReferrers('getReferrers'),

  /// Trigger explicit garbage collection.
  forceGc('forceGc'),

  /// Subscribe to real-time GC event stream.
  startGcStream('startGcStream'),

  /// Stop GC event stream and return buffered events.
  stopGcStream('stopGcStream'),

  /// Record memory timeline over a duration window.
  getMemoryTimeline('getMemoryTimeline'),

  /// Monitor GC frequency and pressure level over time.
  watchGcPressure('watchGcPressure'),

  /// Return plain English breakdown of heap/RSS/external memory.
  explainMemoryBreakdown('explainMemoryBreakdown');

  const MemoryAction(this.value);

  @override
  final String value;

  static final Map<String, MemoryAction> _lookup = {
    for (final e in MemoryAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static MemoryAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
