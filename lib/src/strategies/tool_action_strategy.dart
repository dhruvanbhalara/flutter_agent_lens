import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';

/// Strategy interface for executing an MCP composite tool action.
abstract interface class ToolActionStrategy {
  /// Unique name of the action (e.g. 'save', 'inspect', 'fetch').
  String get actionName;

  /// Executes the tool action against the connected application client context.
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  );
}

/// A registry mapping action names to their corresponding [ToolActionStrategy].
final class ToolActionRegistry {
  final Map<String, ToolActionStrategy> _strategies = {};

  /// Creates a new [ToolActionRegistry] optionally initialized with [strategies].
  ToolActionRegistry([Iterable<ToolActionStrategy>? strategies]) {
    if (strategies != null) {
      registerAll(strategies);
    }
  }

  /// Registers a list of action strategies.
  void registerAll(Iterable<ToolActionStrategy> strategies) {
    for (final strategy in strategies) {
      _strategies[strategy.actionName] = strategy;
    }
  }

  /// Dispatches the request to the matching strategy or returns an error.
  Future<CallToolResult> dispatch(
    String actionName,
    CallToolRequest request,
    IVmServiceClient client,
  ) async {
    final strategy = _strategies[actionName];
    if (strategy == null) {
      return CallToolResult(
        content: [TextContent(text: 'Unknown action: $actionName')],
        isError: true,
      );
    }
    return strategy.execute(request, client);
  }
}
