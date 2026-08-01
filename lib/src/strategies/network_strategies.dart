import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/network_capture_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for network actions delegating to [NetworkCaptureSupport].
abstract base class NetworkActionStrategy implements ToolActionStrategy {
  /// The underlying network capture support mixin instance.
  final NetworkCaptureSupport support;

  /// Creates a [NetworkActionStrategy] instance.
  const NetworkActionStrategy(this.support);
}

/// Strategy for handling the 'start' network capture action.
final class StartNetworkCaptureStrategy extends NetworkActionStrategy {
  /// Creates a [StartNetworkCaptureStrategy] instance.
  const StartNetworkCaptureStrategy(super.support);

  @override
  String get actionName => 'start';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleStartNetworkCapture(request);
}

/// Strategy for handling the 'stop' network capture action.
final class StopNetworkCaptureStrategy extends NetworkActionStrategy {
  /// Creates a [StopNetworkCaptureStrategy] instance.
  const StopNetworkCaptureStrategy(super.support);

  @override
  String get actionName => 'stop';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleStopNetworkCapture(request);
}

/// Strategy for handling the 'get_profile' network action.
final class GetNetworkProfileStrategy extends NetworkActionStrategy {
  /// Creates a [GetNetworkProfileStrategy] instance.
  const GetNetworkProfileStrategy(super.support);

  @override
  String get actionName => 'get_profile';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleGetNetworkProfile(request);
}

/// Strategy for handling the 'watch' network action.
final class WatchNetworkStrategy extends NetworkActionStrategy {
  /// Creates a [WatchNetworkStrategy] instance.
  const WatchNetworkStrategy(super.support);

  @override
  String get actionName => 'watch';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleWatchNetworkRequests(request);
}

/// Strategy for handling the 'get_request_details' network action.
final class GetRequestDetailsStrategy extends NetworkActionStrategy {
  /// Creates a [GetRequestDetailsStrategy] instance.
  const GetRequestDetailsStrategy(super.support);

  @override
  String get actionName => 'get_request_details';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleGetNetworkRequestDetails(request);
}
