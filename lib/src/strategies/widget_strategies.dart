import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/widget_inspection_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for widget actions delegating to [WidgetInspectionSupport].
abstract base class WidgetActionStrategy implements ToolActionStrategy {
  /// The underlying widget inspection support mixin instance.
  final WidgetInspectionSupport support;

  /// Creates a [WidgetActionStrategy] instance.
  const WidgetActionStrategy(this.support);
}

/// Strategy for handling the 'inspect' widget action.
final class InspectLayoutStrategy extends WidgetActionStrategy {
  /// Creates an [InspectLayoutStrategy] instance.
  const InspectLayoutStrategy(super.support);

  @override
  String get actionName => 'inspect';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleInspectWidgetDetails(request);
}

/// Strategy for handling the 'toggle_selection' widget action.
final class ToggleWidgetSelectionStrategy extends WidgetActionStrategy {
  /// Creates a [ToggleWidgetSelectionStrategy] instance.
  const ToggleWidgetSelectionStrategy(super.support);

  @override
  String get actionName => 'toggle_selection';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleToggleWidgetSelectionMode(request);
}

/// Strategy for handling the 'get_tree' widget action.
final class GetWidgetTreeStrategy extends WidgetActionStrategy {
  /// Creates a [GetWidgetTreeStrategy] instance.
  const GetWidgetTreeStrategy(super.support);

  @override
  String get actionName => 'get_tree';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleGetWidgetTree(request);
}
