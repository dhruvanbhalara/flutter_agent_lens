import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/connection_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for connection actions delegating to [ConnectionSupport].
abstract base class ConnectionActionStrategy implements ToolActionStrategy {
  /// The underlying connection support mixin instance.
  final ConnectionSupport support;

  /// Creates a [ConnectionActionStrategy] instance.
  const ConnectionActionStrategy(this.support);
}

/// Strategy for handling the 'connect' tool action.
final class ConnectStrategy extends ConnectionActionStrategy {
  /// Creates a [ConnectStrategy] instance.
  const ConnectStrategy(super.support);

  @override
  String get actionName => 'connect';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleConnect(request);
}

/// Strategy for handling the 'connect_dtd' tool action.
final class ConnectDtdStrategy extends ConnectionActionStrategy {
  /// Creates a [ConnectDtdStrategy] instance.
  const ConnectDtdStrategy(super.support);

  @override
  String get actionName => 'connect_dtd';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleConnectDtd(request);
}

/// Strategy for handling the 'disconnect' tool action.
final class DisconnectStrategy extends ConnectionActionStrategy {
  /// Creates a [DisconnectStrategy] instance.
  const DisconnectStrategy(super.support);

  @override
  String get actionName => 'disconnect';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleDisconnect(request);
}
