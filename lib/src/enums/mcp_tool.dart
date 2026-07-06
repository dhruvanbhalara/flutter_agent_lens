/// Represents all tools registered by the Flutter Agent Lens MCP server.
enum McpTool {
  /// Manage connections to VM Service or Dart Tooling Daemon (DTD).
  connection('connection', requiresConnection: false),

  /// Get detailed information about the connected Flutter app.
  getAppInfo('get_app_info'),

  /// Automatically discover running Flutter apps on this machine.
  discoverApps('discover_apps', requiresConnection: false),

  /// Read recent console logs from stdout, stderr, and developer streams.
  fetchConsoleLogs('fetch_console_logs'),

  /// Fetch the active call stack frames for the running application (when paused).
  getCallStack('get_call_stack'),

  /// Set exception pause mode (None, All, Unhandled).
  setExceptionPauseMode('set_exception_pause_mode'),

  /// Manage breakpoints (add, remove).
  breakpoint('breakpoint'),

  /// Evaluate a Dart expression in the context of the running application.
  evaluateExpression('evaluate_expression'),

  /// Run local build analysis or validate platform deep links on the project.
  diagnoseProject('diagnose_project', requiresConnection: false),

  /// Get the active editor file path and cursor position when connected via DTD.
  getActiveLocation('get_active_location'),

  /// Manage memory snapshots (get_snapshot, save, compare, list).
  memory('memory'),

  /// Audit class instances to find potential memory leaks.
  auditClassMemoryLeak('audit_class_memory_leak'),

  /// Track delta of heap allocations over a period of time.
  diffHeapAllocations('diff_heap_allocations'),

  /// Trace the retaining path keeping an object alive in memory.
  getObjectReferrers('get_object_referrers'),

  /// Manage HTTP network capture (start, stop, get_profile).
  network('network'),

  /// Manage CPU & jank profiling sessions (start, stop, get_cpu, diagnose_jank).
  profiling('profiling'),

  /// Trigger a hot reload on the running application.
  hotReload('hot_reload'),

  /// Trigger a hot restart on the running application.
  hotRestart('hot_restart'),

  /// Compare two screenshots and check for visual differences.
  compareLayoutScreenshots('compare_layout_screenshots'),

  /// Take a screenshot of the running application.
  takeScreenshot('take_screenshot'),

  /// Retrieve layout constraints and details of a widget by its ID.
  inspectWidget('inspect_widget'),

  /// Toggle widget selection mode to select widgets by tapping on the screen.
  toggleWidgetSelection('toggle_widget_selection'),

  /// Toggle showing package widgets in the widget tree.
  togglePackageWidgets('toggle_package_widgets'),

  /// Toggle a Flutter debug flag (e.g. debugPaint, repaintRainbow).
  toggleDebugFlag('toggle_debug_flag'),

  /// Get the widget tree structure.
  getWidgetTree('get_widget_tree'),

  /// Track widget rebuild frequencies (start, stop, get_counts).
  rebuildTracking('rebuild_tracking'),

  /// Trigger a scroll gesture on the running application.
  triggerScrollGesture('trigger_scroll_gesture'),

  /// Set response format for all tools (markdown or json).
  setResponseFormat('set_response_format', requiresConnection: false);

  const McpTool(this.name, {this.requiresConnection = true});

  /// The name of the tool as registered in the MCP server.
  final String name;

  /// Whether this tool requires an active application VM connection.
  final bool requiresConnection;

  static final Map<String, McpTool> _lookup = {
    for (final tool in McpTool.values) tool.name: tool,
  };

  /// Resolves an [McpTool] from its string name. Returns `null` if not found.
  static McpTool? fromName(String name) => _lookup[name];

  @override
  String toString() => name;
}
