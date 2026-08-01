import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/diagnose_project_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for project diagnostics actions delegating to [DiagnoseProjectSupport].
abstract base class DiagnoseProjectActionStrategy
    implements ToolActionStrategy {
  /// The underlying project diagnostics support mixin instance.
  final DiagnoseProjectSupport support;

  /// Creates a [DiagnoseProjectActionStrategy] instance.
  const DiagnoseProjectActionStrategy(this.support);
}

/// Strategy for handling the 'bundle_size' diagnostics action.
final class BundleSizeStrategy extends DiagnoseProjectActionStrategy {
  /// Creates a [BundleSizeStrategy] instance.
  const BundleSizeStrategy(super.support);

  @override
  String get actionName => 'bundle_size';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleAnalyzeBundleSize(request);
}

/// Strategy for handling the 'deep_links' diagnostics action.
final class DeepLinksStrategy extends DiagnoseProjectActionStrategy {
  /// Creates a [DeepLinksStrategy] instance.
  const DeepLinksStrategy(super.support);

  @override
  String get actionName => 'deep_links';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleValidateDeepLinks(request);
}
