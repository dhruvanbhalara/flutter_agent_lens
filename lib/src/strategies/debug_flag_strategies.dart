import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/debug_flag_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for debug flag actions delegating to [DebugFlagSupport].
abstract base class DebugFlagActionStrategy implements ToolActionStrategy {
  /// The underlying debug flag support mixin instance.
  final DebugFlagSupport support;

  /// Creates a [DebugFlagActionStrategy] instance.
  const DebugFlagActionStrategy(this.support);
}

/// Strategy for handling the 'toggle' debug flag action.
final class ToggleDebugFlagStrategy extends DebugFlagActionStrategy {
  /// Creates a [ToggleDebugFlagStrategy] instance.
  const ToggleDebugFlagStrategy(super.support);

  @override
  String get actionName => 'toggle';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleToggleDebugFlag(request);
}

/// Strategy for handling the 'toggle_package_widgets' debug flag action.
final class TogglePackageWidgetsStrategy extends DebugFlagActionStrategy {
  /// Creates a [TogglePackageWidgetsStrategy] instance.
  const TogglePackageWidgetsStrategy(super.support);

  @override
  String get actionName => 'toggle_package_widgets';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleTogglePackageWidgets(request);
}
