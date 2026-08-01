import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/rebuild_tracking_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for rebuild tracking actions delegating to [RebuildTrackingSupport].
abstract base class RebuildTrackingActionStrategy
    implements ToolActionStrategy {
  /// The underlying rebuild tracking support mixin instance.
  final RebuildTrackingSupport support;

  /// Creates a [RebuildTrackingActionStrategy] instance.
  const RebuildTrackingActionStrategy(this.support);
}

/// Strategy for handling the 'start' rebuild tracking action.
final class StartRebuildTrackingStrategy extends RebuildTrackingActionStrategy {
  /// Creates a [StartRebuildTrackingStrategy] instance.
  const StartRebuildTrackingStrategy(super.support);

  @override
  String get actionName => 'start';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleStartTrackingRebuilds(request);
}

/// Strategy for handling the 'stop' rebuild tracking action.
final class StopRebuildTrackingStrategy extends RebuildTrackingActionStrategy {
  /// Creates a [StopRebuildTrackingStrategy] instance.
  const StopRebuildTrackingStrategy(super.support);

  @override
  String get actionName => 'stop';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleStopTrackingRebuilds(request);
}

/// Strategy for handling the 'get_counts' rebuild tracking action.
final class GetRebuildCountsStrategy extends RebuildTrackingActionStrategy {
  /// Creates a [GetRebuildCountsStrategy] instance.
  const GetRebuildCountsStrategy(super.support);

  @override
  String get actionName => 'get_counts';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleWidgetRebuildCounts(request);
}
