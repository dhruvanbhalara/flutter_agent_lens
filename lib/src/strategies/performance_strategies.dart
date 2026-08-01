import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/mixins/performance_profiling_support.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';

/// Base abstract strategy for performance profiling actions delegating to [PerformanceProfilingSupport].
abstract base class PerformanceActionStrategy implements ToolActionStrategy {
  /// The underlying performance profiling support mixin instance.
  final PerformanceProfilingSupport support;

  /// Creates a [PerformanceActionStrategy] instance.
  const PerformanceActionStrategy(this.support);
}

/// Strategy for handling the 'start' profiling action.
final class StartProfilingStrategy extends PerformanceActionStrategy {
  /// Creates a [StartProfilingStrategy] instance.
  const StartProfilingStrategy(super.support);

  @override
  String get actionName => 'start';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleStartProfiling(request);
}

/// Strategy for handling the 'stop' profiling action.
final class StopProfilingStrategy extends PerformanceActionStrategy {
  /// Creates a [StopProfilingStrategy] instance.
  const StopProfilingStrategy(super.support);

  @override
  String get actionName => 'stop';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleStopProfiling(request);
}

/// Strategy for handling the 'get_cpu' profiling action.
final class GetCpuProfileStrategy extends PerformanceActionStrategy {
  /// Creates a [GetCpuProfileStrategy] instance.
  const GetCpuProfileStrategy(super.support);

  @override
  String get actionName => 'get_cpu';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleGetCpuProfile(request);
}

/// Strategy for handling the 'diagnose_jank' profiling action.
final class DiagnoseJankStrategy extends PerformanceActionStrategy {
  /// Creates a [DiagnoseJankStrategy] instance.
  const DiagnoseJankStrategy(super.support);

  @override
  String get actionName => 'diagnose_jank';

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) =>
      support.handleDiagnoseJank(request);
}
