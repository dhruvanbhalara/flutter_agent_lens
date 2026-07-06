import 'dart:async';
import 'package:dart_mcp/server.dart';
import 'package:stream_channel/stream_channel.dart';

import 'src/enums/mcp_tool.dart';
import 'src/mixins/vm_connection_support.dart';
import 'src/mixins/connection_support.dart';
import 'src/mixins/console_logging_support.dart';
import 'src/mixins/debugger_support.dart';
import 'src/mixins/memory_debugging_support.dart';
import 'src/mixins/network_capture_support.dart';
import 'src/mixins/performance_profiling_support.dart';
import 'src/mixins/screenshot_support.dart';
import 'src/mixins/widget_inspection_support.dart';
import 'src/mixins/rebuild_tracking_support.dart';
import 'src/mixins/debug_flag_support.dart';
import 'src/mixins/scroll_gesture_support.dart';
import 'src/mixins/diagnose_project_support.dart';

/// Flutter Agent Lens MCP Server class.
///
/// This server exposes a suite of tools that allow AI agents to debug,
/// profile, and inspect running Flutter applications over an MCP channel.
final class FlutterAgentLensServer extends MCPServer
    with
        ToolsSupport,
        LoggingSupport,
        RootsTrackingSupport,
        VmConnectionSupport,
        ConsoleLoggingSupport,
        WidgetInspectionSupport,
        RebuildTrackingSupport,
        DebugFlagSupport,
        ScrollGestureSupport,
        PerformanceProfilingSupport,
        MemoryDebuggingSupport,
        NetworkCaptureSupport,
        DebuggerSupport,
        ScreenshotSupport,
        ConnectionSupport,
        DiagnoseProjectSupport {
  /// Creates a new [FlutterAgentLensServer] instance communicating over the given [channel].
  FlutterAgentLensServer({required StreamChannel<String> channel})
      : super.fromStreamChannel(
          channel,
          implementation: Implementation(
            name: 'flutter_agent_lens',
            version: '1.5.4',
          ),
          instructions: 'A tool server to interact with running Flutter apps. '
              'Connect using the connect tool, or discover running apps with discover_apps.',
        );

  /// Cleans up active streams and subscriptions on connection close.
  @override
  Future<void> cleanupStreams() async {
    await cleanupLogging();
    await cleanupWidgetInspection();
    await cleanupRebuildTracking();
    await cleanupPerformanceProfiling();
    cleanupMemoryDebugging();
    await cleanupNetworkCapture();
    await serviceStreamSub?.cancel();
    serviceStreamSub = null;
    registeredMethodsForService.clear();
    cachedLibraryId = null;
    await dtdClient?.close();
    dtdClient = null;
    dtdUri = null;
  }

  /// Initializes the server and registers all supported tools.
  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    _registerTools();
    return result;
  }

  /// Track whether connected tools are currently registered.
  bool _connectedToolsRegistered = false;

  /// Registers all connection and project diagnostics tools at startup.
  void _registerTools() {
    registerConnectionTools();
    registerDiagnoseProjectTools();
  }

  /// Registers all tools requiring active VM connection.
  @override
  void registerConnectedTools() {
    if (_connectedToolsRegistered) {
      unregisterConnectedTools();
    }
    registerWidgetTools();
    registerRebuildTrackingTools();
    registerDebugFlagTools();
    registerScrollGestureTools();
    registerPerformanceTools();
    registerMemoryTools();
    registerLoggingTools();
    registerNetworkTools();
    registerDebuggerTools();
    registerScreenshotTools();
    registerAppInfoTools();
    registerDtdTools();
    _connectedToolsRegistered = true;
  }

  /// Unregisters all tools requiring active VM connection.
  @override
  void unregisterConnectedTools() {
    if (!_connectedToolsRegistered) return;
    for (final tool in McpTool.values) {
      if (tool.requiresConnection) {
        unregisterTool(tool.name);
      }
    }
    _connectedToolsRegistered = false;
  }
}
