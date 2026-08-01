import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/console_logging_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for console logging actions delegating to [ConsoleLoggingSupport].
abstract base class ConsoleLoggingActionStrategy implements ToolActionStrategy {
  /// The underlying console logging support mixin instance.
  final ConsoleLoggingSupport support;

  /// Creates a [ConsoleLoggingActionStrategy] instance.
  const ConsoleLoggingActionStrategy(this.support);
}

/// Strategy for handling the 'fetch' console logs action.
final class FetchConsoleLogsStrategy extends ConsoleLoggingActionStrategy {
  /// Creates a [FetchConsoleLogsStrategy] instance.
  const FetchConsoleLogsStrategy(super.support);

  @override
  String get actionName => 'fetch';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleFetchConsoleLogs(request);
}

/// Strategy for handling the 'watch' console logs action.
final class WatchLogsStrategy extends ConsoleLoggingActionStrategy {
  /// Creates a [WatchLogsStrategy] instance.
  const WatchLogsStrategy(super.support);

  @override
  String get actionName => 'watch';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleWatchLogs(request);
}
