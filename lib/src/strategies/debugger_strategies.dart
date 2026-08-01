import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/debugger_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for breakpoint actions delegating to [DebuggerSupport].
abstract base class DebuggerActionStrategy implements ToolActionStrategy {
  /// The underlying debugger support mixin instance.
  final DebuggerSupport support;

  /// Creates a [DebuggerActionStrategy] instance.
  const DebuggerActionStrategy(this.support);
}

/// Strategy for handling the 'add' breakpoint action.
final class AddBreakpointStrategy extends DebuggerActionStrategy {
  /// Creates an [AddBreakpointStrategy] instance.
  const AddBreakpointStrategy(super.support);

  @override
  String get actionName => 'add';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleAddBreakpoint(request);
}

/// Strategy for handling the 'remove' breakpoint action.
final class RemoveBreakpointStrategy extends DebuggerActionStrategy {
  /// Creates a [RemoveBreakpointStrategy] instance.
  const RemoveBreakpointStrategy(super.support);

  @override
  String get actionName => 'remove';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleRemoveBreakpoint(request);
}
