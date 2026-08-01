import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/screenshot_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for screenshot actions delegating to [ScreenshotSupport].
abstract base class ScreenshotActionStrategy implements ToolActionStrategy {
  /// The underlying screenshot support mixin instance.
  final ScreenshotSupport support;

  /// Creates a [ScreenshotActionStrategy] instance.
  const ScreenshotActionStrategy(this.support);
}

/// Strategy for handling the 'take' screenshot action.
final class TakeScreenshotStrategy extends ScreenshotActionStrategy {
  /// Creates a [TakeScreenshotStrategy] instance.
  const TakeScreenshotStrategy(super.support);

  @override
  String get actionName => 'take';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleTakeScreenshot(request);
}

/// Strategy for handling the 'capture_baseline' screenshot action.
final class CaptureBaselineStrategy extends ScreenshotActionStrategy {
  /// Creates a [CaptureBaselineStrategy] instance.
  const CaptureBaselineStrategy(super.support);

  @override
  String get actionName => 'capture_baseline';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleCompareLayoutScreenshots(request);
}

/// Strategy for handling the 'compare' screenshot action.
final class CompareScreenshotStrategy extends ScreenshotActionStrategy {
  /// Creates a [CompareScreenshotStrategy] instance.
  const CompareScreenshotStrategy(super.support);

  @override
  String get actionName => 'compare';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleCompareLayoutScreenshots(request);
}
