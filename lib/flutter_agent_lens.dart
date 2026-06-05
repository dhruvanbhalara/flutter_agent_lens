import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;

import 'src/path_resolver.dart';
import 'src/port_discovery.dart';

part 'src/handlers/connection_handlers.dart';
part 'src/handlers/widget_handlers.dart';
part 'src/handlers/performance_handlers.dart';
part 'src/handlers/memory_handlers.dart';
part 'src/handlers/logging_handlers.dart';
part 'src/handlers/network_handlers.dart';
part 'src/handlers/debugger_handlers.dart';

part 'src/handlers/bundle_handlers.dart';
part 'src/handlers/deeplink_handlers.dart';
part 'src/handlers/screenshot_handlers.dart';

/// Flutter Agent Lens MCP Server.
final class FlutterAgentLensServer extends MCPServer with ToolsSupport {
  FlutterAgentLensServer({required StreamChannel<String> channel})
      : super.fromStreamChannel(
          channel,
          implementation: Implementation(
            name: 'flutter_agent_lens',
            version: '1.2.0',
          ),
          instructions: 'A tool server to interact with running Flutter apps. '
              'Connect using the connect tool, or discover running apps with discover_apps.',
        );

  VmService? _vmService;
  String? _vmServiceUri;
  String? _isolateId;
  String? _workspaceRoot;
  PathResolver? _pathResolver;
  String? _cachedLibraryId;
  final Map<String, _MemorySnapshot> _memorySnapshots = {};

  final List<String> _logBuffer = [];
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  StreamSubscription? _loggingSub;

  void _cleanupStreams() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _loggingSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _loggingSub = null;
    _cachedLibraryId = null;
    _memorySnapshots.clear();
  }

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    _registerTools();
    return result;
  }

  void _registerTools() {
    // Get Widget Rebuild Counts
    registerTool(
      Tool(
        name: 'get_widget_rebuild_counts',
        description:
            'Find widgets that rebuild frequently by tracking rebuild counts.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds': NumberSchema(
              description: 'Duration to watch and count rebuilds (default: 3).',
            ),
          },
        ),
      ),
      _handleWidgetRebuildCounts,
    );

    // Diagnose Jank
    registerTool(
      Tool(
        name: 'diagnose_jank',
        description: 'Check frame times to find rendering slowdowns (jank).',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds': NumberSchema(
              description: 'Sampling window in seconds (default: 3).',
            ),
          },
        ),
      ),
      _handleDiagnoseJank,
    );

    // Audit Memory Leaks
    registerTool(
      Tool(
        name: 'audit_class_memory_leak',
        description: 'Check if class instances are leaking in memory.',
        inputSchema: ObjectSchema(
          properties: {
            'class_name': StringSchema(
              description:
                  'Name of the class to inspect (e.g. _MyHomePageState).',
            ),
          },
          required: ['class_name'],
        ),
      ),
      _handleAuditClassMemoryLeak,
    );

    // Hot Reload
    registerTool(
      Tool(
        name: 'hot_reload',
        description: 'Trigger a hot reload.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      handleHotReload,
    );

    // Hot Restart
    registerTool(
      Tool(
        name: 'hot_restart',
        description: 'Trigger a hot restart of the application.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      handleHotRestart,
    );

    // Trigger Scroll Gesture
    registerTool(
      Tool(
        name: 'trigger_scroll_gesture',
        description: 'Simulate user scrolling by animating a ScrollController.',
        inputSchema: ObjectSchema(
          properties: {
            'scroll_controller_expression': StringSchema(
              description:
                  'Dart expression that evaluates to the ScrollController (e.g., PrimaryScrollController.of(primaryFocus!.context)).',
            ),
            'offset': NumberSchema(
              description: 'Pixel offset to scroll to (default: 500.0).',
            ),
          },
          required: ['scroll_controller_expression'],
        ),
      ),
      _handleScrollGesture,
    );

    // Fetch Console Logs
    registerTool(
      Tool(
        name: 'fetch_console_logs',
        description:
            'Read recent console logs from stdout, stderr, and developer streams.',
        inputSchema: ObjectSchema(
          properties: {
            'limit': NumberSchema(
              description:
                  'Maximum log lines to return (default: 50, max: 200).',
            ),
          },
        ),
      ),
      _handleFetchConsoleLogs,
    );

    // Get CPU Profile
    registerTool(
      Tool(
        name: 'get_cpu_profile',
        description:
            'Sample CPU usage and find execution hotspots in Dart functions.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds': NumberSchema(
              description: 'Profile sampling window in seconds (default: 3).',
            ),
          },
        ),
      ),
      _handleGetCpuProfile,
    );

    // Get Network Profile
    registerTool(
      Tool(
        name: 'get_network_profile',
        description: 'Fetch network profile request histories.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleGetNetworkProfile,
    );

    // Toggle Widget Selection Mode
    registerTool(
      Tool(
        name: 'toggle_widget_selection',
        description:
            'Enable or disable on-device widget selection (Widget Inspector overlay) mode.',
        inputSchema: ObjectSchema(
          properties: {
            'enabled': BooleanSchema(
              description:
                  'Whether to enable or disable widget selection mode.',
            ),
          },
          required: ['enabled'],
        ),
      ),
      _handleToggleWidgetSelection,
    );

    // Toggle Package Widgets Visibility
    registerTool(
      Tool(
        name: 'toggle_package_widgets',
        description:
            'Toggle whether widgets created by external packages and the Flutter framework are shown in the widget tree and rebuild metrics.',
        inputSchema: ObjectSchema(
          properties: {
            'enabled': BooleanSchema(
              description: 'Whether to show package and framework widgets.',
            ),
          },
          required: ['enabled'],
        ),
      ),
      _handleTogglePackageWidgets,
    );

    // Memory Allocations Delta
    registerTool(
      Tool(
        name: 'diff_heap_allocations',
        description:
            'Calculate class instance count and size deltas over a sampling window.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds': NumberSchema(
              description: 'Sampling window duration in seconds (default: 3).',
            ),
            'expression': StringSchema(
              description:
                  'An optional Dart expression to evaluate during the window to trigger state modifications.',
            ),
            'force_gc': BooleanSchema(
              description:
                  'Force garbage collection before capturing snapshots to clear dead references (default: true).',
            ),
          },
        ),
      ),
      _handleDiffHeapAllocations,
    );

    // Analyze Bundle Size
    registerTool(
      Tool(
        name: 'analyze_bundle_size',
        description:
            'Analyze build size details from size mapping files in the build/ directory.',
        inputSchema: ObjectSchema(
          properties: {
            'build_target': StringSchema(
              description:
                  'Target format to inspect (e.g. apk, appbundle, ios, web; default: apk).',
            ),
          },
        ),
      ),
      _handleAnalyzeBundleSize,
    );

    // Get Call Stack
    registerTool(
      Tool(
        name: 'get_call_stack',
        description:
            'Retrieve stack frames of running or paused isolates for debugger inspection.',
        inputSchema: ObjectSchema(
          properties: {
            'limit': NumberSchema(
              description: 'Maximum frame depth to return (default: 20).',
            ),
          },
        ),
      ),
      _handleGetCallStack,
    );

    // Set Exception Pause Mode
    registerTool(
      Tool(
        name: 'set_exception_pause_mode',
        description: 'Configure the VM debugger exception pausing behavior.',
        inputSchema: ObjectSchema(
          properties: {
            'mode': StringSchema(
              description: 'Pause mode to apply (None, Unhandled, All).',
            ),
          },
          required: ['mode'],
        ),
      ),
      _handleSetExceptionPauseMode,
    );

    // Validate Deep Links
    registerTool(
      Tool(
        name: 'validate_deep_links',
        description: 'Validate deep link configurations on Android or iOS.',
        inputSchema: ObjectSchema(
          properties: {
            'platform': StringSchema(
              description: 'The target platform (android or ios).',
            ),
            'build_variant': StringSchema(
              description:
                  'The build variant for Android (e.g., debug, release).',
            ),
            'configuration': StringSchema(
              description:
                  'The build configuration for iOS (e.g., Debug, Release).',
            ),
            'target': StringSchema(
              description: 'The target name for iOS (default: Runner).',
            ),
          },
          required: ['platform'],
        ),
      ),
      _handleValidateDeepLinks,
    );

    // Toggle Debug Flag
    registerTool(
      Tool(
        name: 'toggle_debug_flag',
        description:
            'Configure Flutter framework debug flags or performance overlays.',
        inputSchema: ObjectSchema(
          properties: {
            'flag_name': StringSchema(
              description:
                  'The flag name without the ext.flutter prefix. Supported flags: '
                  'debugPaint (overlay layout guidelines), '
                  'invertOversizedImages (highlight oversized images), '
                  'repaintRainbow (show borders when elements repaint), '
                  'debugPaintBaselinesEnabled (show baselines), '
                  'timeDilation (slow animation factor).',
            ),
            'value': StringSchema(
              description:
                  'The target value (e.g., "true", "false", or a double multiplier like "5.0" for timeDilation).',
            ),
          },
          required: ['flag_name', 'value'],
        ),
      ),
      _handleToggleDebugFlag,
    );

    // Get Object Referrers
    registerTool(
      Tool(
        name: 'get_object_referrers',
        description: 'Find references that keep an object alive in the heap.',
        inputSchema: ObjectSchema(
          properties: {
            'object_id': StringSchema(
              description: 'The unique ID of the object.',
            ),
            'limit': NumberSchema(
              description: 'Maximum depth for reference search (default: 15).',
            ),
          },
          required: ['object_id'],
        ),
      ),
      _handleGetObjectReferrers,
    );

    // Add Breakpoint
    registerTool(
      Tool(
        name: 'add_breakpoint',
        description: 'Install a breakpoint at a specific line in a file.',
        inputSchema: ObjectSchema(
          properties: {
            'file_path': StringSchema(
              description:
                  'The absolute path or file URI of the target source file.',
            ),
            'line': NumberSchema(
              description: 'The 1-based line number.',
            ),
            'column': NumberSchema(
              description: 'The optional 1-based column number.',
            ),
          },
          required: ['file_path', 'line'],
        ),
      ),
      _handleAddBreakpoint,
    );

    // Remove Breakpoint
    registerTool(
      Tool(
        name: 'remove_breakpoint',
        description: 'Remove an active breakpoint by its ID.',
        inputSchema: ObjectSchema(
          properties: {
            'breakpoint_id': StringSchema(
              description: 'The unique ID of the breakpoint to remove.',
            ),
          },
          required: ['breakpoint_id'],
        ),
      ),
      _handleRemoveBreakpoint,
    );

    // Connect (Alias)
    registerTool(
      Tool(
        name: 'connect',
        description: 'Connect to a running Flutter app via its VM Service URI.',
        inputSchema: ObjectSchema(
          properties: {
            'uri': StringSchema(
              description:
                  'The VM Service HTTP or WS URI (e.g. http://127.0.0.1:8181/auth_token=/).',
            ),
            'vmServiceUri': StringSchema(
              description:
                  'Alias for the uri parameter.',
            ),
            'workspace_root': StringSchema(
              description:
                  'Absolute path to the local Flutter project root directory.',
            ),
          },
        ),
      ),
      _handleConnect,
    );

    // Disconnect (Alias)
    registerTool(
      Tool(
        name: 'disconnect',
        description: 'Disconnect from the currently connected Flutter app.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleDisconnect,
    );

    // Get App Info (Alias)
    registerTool(
      Tool(
        name: 'get_app_info',
        description:
            'Get detailed information about the connected Flutter app including VM info, isolates, and available extensions.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleGetAppInfo,
    );

    // Discover Apps (Alias)
    registerTool(
      Tool(
        name: 'discover_apps',
        description:
            'Automatically discover running Flutter apps on this machine.',
        inputSchema: ObjectSchema(
          properties: {
            'autoConnect': BooleanSchema(
              description:
                  'Automatically connect to the first discovered app (default: true).',
            ),
            'workspace_root': StringSchema(
              description:
                  'Absolute path to the local Flutter project root directory.',
            ),
          },
        ),
      ),
      _handleAutodiscover,
    );

    // Evaluate Expression (Alias)
    registerTool(
      Tool(
        name: 'evaluate_expression',
        description:
            'Evaluate a Dart expression in the context of the running app.',
        inputSchema: ObjectSchema(
          properties: {
            'expression': StringSchema(
              description: 'The Dart expression to evaluate.',
            ),
            'frame_index': NumberSchema(
              description: 'Optional frame index to evaluate the expression in (if the app is paused at a breakpoint).',
            ),
          },
          required: ['expression'],
        ),
      ),
      _handleEvalExpression,
    );

    // Inspect Widget (Alias)
    registerTool(
      Tool(
        name: 'inspect_widget',
        description:
            'Retrieve layout constraints and details of a widget by its ID.',
        inputSchema: ObjectSchema(
          properties: {
            'widgetId': StringSchema(
              description: 'The unique widget details ID.',
            ),
          },
          required: ['widgetId'],
        ),
      ),
      _handleInspectLayoutConstraints,
    );

    // Compare Layout Screenshots
    registerTool(
      Tool(
        name: 'compare_layout_screenshots',
        description: 'Capture screenshots and perform pixel diff checks to find layout changes or bugs.',
        inputSchema: ObjectSchema(
          properties: {
            'baseline_name': StringSchema(
              description: 'The filename prefix for the baseline screenshot (e.g. "home_screen").',
            ),
            'action': StringSchema(
              description: 'The visual operation to execute (capture_baseline, compare).',
            ),
            'threshold': NumberSchema(
              description: 'The similarity pass threshold from 0.0 to 1.0 (default: 0.98).',
            ),
            'screenshot_type': StringSchema(
              description: 'The format/method to capture (device = native screenshot, skia = Skia Picture via VM service; default: device).',
            ),
            'device_id': StringSchema(
              description: 'Target device ID or name if multiple devices are connected (prefixes allowed).',
            ),
          },
          required: ['baseline_name', 'action'],
        ),
      ),
      _handleCompareLayoutScreenshots,
    );

    // Take Standalone Screenshot
    registerTool(
      Tool(
        name: 'take_screenshot',
        description: 'Capture a standalone screenshot of the running Flutter application.',
        inputSchema: ObjectSchema(
          properties: {
            'screenshot_type': StringSchema(
              description: 'The capture method (device = native screenshot, skia = Skia Picture via VM service; default: device).',
            ),
            'device_id': StringSchema(
              description: 'Target device ID or name if multiple devices are connected.',
            ),
            'output_path': StringSchema(
              description: 'Optional destination file path. If not specified, the screenshot will be saved to a default directory.',
            ),
          },
        ),
      ),
      _handleTakeScreenshot,
    );

    // Get Widget Tree
    registerTool(
      Tool(
        name: 'get_widget_tree',
        description: 'Get the current widget tree of the running Flutter application.',
        inputSchema: ObjectSchema(
          properties: {
            'maxDepth': NumberSchema(
              description: 'Maximum depth of the widget tree to return (default: 15).',
            ),
            'projectOnly': BooleanSchema(
              description: 'If true, only return widgets created by the local project code.',
            ),
          },
        ),
      ),
      _handleGetWidgetTree,
    );

    // Save Snapshot
    registerTool(
      Tool(
        name: 'save_snapshot',
        description: 'Save a named memory snapshot for later comparison.',
        inputSchema: ObjectSchema(
          properties: {
            'name': StringSchema(
              description: 'A name for this snapshot (e.g., "before-fix", "after-optimization").',
            ),
            'forceGC': BooleanSchema(
              description: 'Force garbage collection before snapshot (default: true).',
            ),
          },
          required: ['name'],
        ),
      ),
      _handleSaveSnapshot,
    );

    // Compare Snapshots
    registerTool(
      Tool(
        name: 'compare_snapshots',
        description: 'Compare two previously saved memory snapshots to see deltas.',
        inputSchema: ObjectSchema(
          properties: {
            'before': StringSchema(
              description: 'Name of the before snapshot.',
            ),
            'after': StringSchema(
              description: 'Name of the after snapshot.',
            ),
          },
          required: ['before', 'after'],
        ),
      ),
      _handleCompareSnapshots,
    );

    // List Snapshots
    registerTool(
      Tool(
        name: 'list_snapshots',
        description: 'List all saved memory snapshots available for comparison.',
        inputSchema: ObjectSchema(properties: {}),
      ),
      _handleListSnapshots,
    );
  }

  CallToolResult _notConnected() {
    return CallToolResult(
      content: [
        TextContent(
            text:
                'Not connected to a running application. Run connect first.')
      ],
      isError: true,
    );
  }

  CallToolResult _serializeDualFormat({
    required String title,
    required String markdownBody,
    required Map<String, dynamic> structuredData,
  }) {
    final contentBuffer = StringBuffer()
      ..writeln(title)
      ..writeln()
      ..writeln(markdownBody)
      ..writeln()
      ..writeln('```json')
      ..writeln(const JsonEncoder.withIndent('  ').convert(structuredData))
      ..writeln('```');

    return CallToolResult(
      content: [
        TextContent(text: contentBuffer.toString()),
      ],
    );
  }

  String _normalizeToWsUri(String uri) {
    var ws = uri.trim();
    if (!ws.startsWith('ws')) {
      ws = ws
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://');
    }
    if (!ws.endsWith('/ws')) {
      ws = ws.replaceAll(RegExp(r'/?$'), '/ws');
    }
    return ws;
  }

  Future<String> _getEvaluationLibraryId() async {
    if (_vmService == null || _isolateId == null) {
      throw StateError('Not connected to a running application.');
    }
    if (_cachedLibraryId != null) {
      return _cachedLibraryId!;
    }

    final isolate = await _vmService!.getIsolate(_isolateId!);
    final libraries = isolate.libraries ?? [];
    if (libraries.isEmpty) {
      throw StateError('No libraries found in target isolate.');
    }

    // Return the main application library ID if found, otherwise the first library.
    for (final lib in libraries) {
      final uri = lib.uri ?? '';
      if (uri.startsWith('package:') && !uri.contains('package:flutter/')) {
        _cachedLibraryId = lib.id;
        return lib.id!;
      }
    }

    _cachedLibraryId = libraries.first.id;
    return libraries.first.id!;
  }
}
