import 'dart:async';
import 'package:dart_mcp/server.dart';
import 'package:stream_channel/stream_channel.dart';

import 'src/mixins/vm_connection_support.dart';
import 'src/mixins/connection_support.dart';
import 'src/mixins/console_logging_support.dart';
import 'src/mixins/debugger_support.dart';
import 'src/mixins/memory_debugging_support.dart';
import 'src/mixins/network_capture_support.dart';
import 'src/mixins/performance_profiling_support.dart';
import 'src/mixins/screenshot_support.dart';
import 'src/mixins/widget_inspection_support.dart';
import 'src/mixins/bundle_analysis_support.dart';
import 'src/mixins/deeplink_validation_support.dart';
import 'src/mixins/dtd_support.dart';

/// Flutter Agent Lens MCP Server.
final class FlutterAgentLensServer extends MCPServer
    with
        ToolsSupport,
        LoggingSupport,
        RootsTrackingSupport,
        VmConnectionSupport,
        ConsoleLoggingSupport,
        WidgetInspectionSupport,
        PerformanceProfilingSupport,
        MemoryDebuggingSupport,
        NetworkCaptureSupport,
        DebuggerSupport,
        ScreenshotSupport,
        ConnectionSupport,
        BundleAnalysisSupport,
        DeeplinkValidationSupport,
        DtdSupport {
  FlutterAgentLensServer({required StreamChannel<String> channel})
      : super.fromStreamChannel(
          channel,
          implementation: Implementation(
            name: 'flutter_agent_lens',
            version: '1.5.3',
          ),
          instructions: 'A tool server to interact with running Flutter apps. '
              'Connect using the connect tool, or discover running apps with discover_apps.',
        );

  @override
  void cleanupStreams() {
    cleanupLogging();
    cleanupWidgetInspection();
    cleanupPerformanceProfiling();
    cleanupMemoryDebugging();
    cleanupNetworkCapture();
    serviceStreamSub?.cancel();
    serviceStreamSub = null;
    registeredMethodsForService.clear();
    cachedLibraryId = null;
    dtdClient?.close();
    dtdClient = null;
    dtdUri = null;
  }

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    _registerTools();
    return result;
  }

  void _registerTools() {
    registerConnectionTools();
    registerWidgetTools();
    registerPerformanceTools();
    registerMemoryTools();
    registerLoggingTools();
    registerNetworkTools();
    registerDebuggerTools();
    registerScreenshotTools();
    registerBundleAnalysisTools();
    registerDeeplinkTools();
    registerDtdTools();
  }
}
