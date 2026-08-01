import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/memory_debugging_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for memory actions delegating to [MemoryDebuggingSupport].
abstract base class MemoryActionStrategy implements ToolActionStrategy {
  /// The underlying memory debugging support mixin instance.
  final MemoryDebuggingSupport support;

  /// Creates a [MemoryActionStrategy] instance.
  const MemoryActionStrategy(this.support);
}

/// Strategy for handling the 'get_snapshot' memory action.
final class GetSnapshotStrategy extends MemoryActionStrategy {
  /// Creates a [GetSnapshotStrategy] instance.
  const GetSnapshotStrategy(super.support);

  @override
  String get actionName => 'get_snapshot';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleGetMemorySnapshot(request);
}

/// Strategy for handling the 'save' memory action.
final class SaveSnapshotStrategy extends MemoryActionStrategy {
  /// Creates a [SaveSnapshotStrategy] instance.
  const SaveSnapshotStrategy(super.support);

  @override
  String get actionName => 'save';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleSaveSnapshot(request);
}

/// Strategy for handling the 'compare' memory action.
final class CompareSnapshotsStrategy extends MemoryActionStrategy {
  /// Creates a [CompareSnapshotsStrategy] instance.
  const CompareSnapshotsStrategy(super.support);

  @override
  String get actionName => 'compare';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleCompareSnapshots(request);
}

/// Strategy for handling the 'list' memory action.
final class ListSnapshotsStrategy extends MemoryActionStrategy {
  /// Creates a [ListSnapshotsStrategy] instance.
  const ListSnapshotsStrategy(super.support);

  @override
  String get actionName => 'list';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleListSnapshots(request);
}

/// Strategy for handling the 'audit_leak' memory action.
final class AuditLeakStrategy extends MemoryActionStrategy {
  /// Creates an [AuditLeakStrategy] instance.
  const AuditLeakStrategy(super.support);

  @override
  String get actionName => 'audit_leak';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleAuditClassMemoryLeak(request);
}

/// Strategy for handling the 'diff_allocations' memory action.
final class DiffAllocationsStrategy extends MemoryActionStrategy {
  /// Creates a [DiffAllocationsStrategy] instance.
  const DiffAllocationsStrategy(super.support);

  @override
  String get actionName => 'diff_allocations';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleDiffHeapAllocations(request);
}

/// Strategy for handling the 'get_referrers' memory action.
final class GetReferrersStrategy extends MemoryActionStrategy {
  /// Creates a [GetReferrersStrategy] instance.
  const GetReferrersStrategy(super.support);

  @override
  String get actionName => 'get_referrers';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleGetObjectReferrers(request);
}

/// Strategy for handling the 'force_gc' memory action.
final class ForceGcStrategy extends MemoryActionStrategy {
  /// Creates a [ForceGcStrategy] instance.
  const ForceGcStrategy(super.support);

  @override
  String get actionName => 'force_gc';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleForceGc(request);
}

/// Strategy for handling the 'start_gc_stream' memory action.
final class StartGcStreamStrategy extends MemoryActionStrategy {
  /// Creates a [StartGcStreamStrategy] instance.
  const StartGcStreamStrategy(super.support);

  @override
  String get actionName => 'start_gc_stream';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleStartGcStream(request);
}

/// Strategy for handling the 'stop_gc_stream' memory action.
final class StopGcStreamStrategy extends MemoryActionStrategy {
  /// Creates a [StopGcStreamStrategy] instance.
  const StopGcStreamStrategy(super.support);

  @override
  String get actionName => 'stop_gc_stream';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleStopGcStream(request);
}

/// Strategy for handling the 'get_memory_timeline' memory action.
final class GetMemoryTimelineStrategy extends MemoryActionStrategy {
  /// Creates a [GetMemoryTimelineStrategy] instance.
  const GetMemoryTimelineStrategy(super.support);

  @override
  String get actionName => 'get_memory_timeline';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleGetMemoryTimeline(request);
}

/// Strategy for handling the 'watch_gc_pressure' memory action.
final class WatchGcPressureStrategy extends MemoryActionStrategy {
  /// Creates a [WatchGcPressureStrategy] instance.
  const WatchGcPressureStrategy(super.support);

  @override
  String get actionName => 'watch_gc_pressure';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleWatchGcPressure(request);
}

/// Strategy for handling the 'explain_memory_breakdown' memory action.
final class ExplainMemoryBreakdownStrategy extends MemoryActionStrategy {
  /// Creates an [ExplainMemoryBreakdownStrategy] instance.
  const ExplainMemoryBreakdownStrategy(super.support);

  @override
  String get actionName => 'explain_memory_breakdown';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleExplainMemoryBreakdown(request);
}
