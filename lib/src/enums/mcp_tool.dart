/// Represents all tools registered by the Flutter Agent Lens MCP server.
enum McpTool {
  /// Connect to a running Flutter app via its VM Service URI.
  connect('connect', requiresConnection: false),

  /// Disconnect from the currently connected Flutter app.
  disconnect('disconnect'),

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

  /// Add a breakpoint at a specific line in a source file.
  addBreakpoint('add_breakpoint'),

  /// Remove a breakpoint by its ID.
  removeBreakpoint('remove_breakpoint'),

  /// Evaluate a Dart expression in the context of the running application.
  evaluateExpression('evaluate_expression'),

  /// Validate deep link configurations on Android or iOS.
  validateDeepLinks('validate_deep_links', requiresConnection: false),

  /// Connect to the Dart Tooling Daemon (DTD).
  connectDtd('connect_dtd', requiresConnection: false),

  /// Get the active editor file path and cursor position when connected via DTD.
  getActiveLocation('get_active_location', requiresConnection: false),

  /// Get a general snapshot overview of application and framework class allocations.
  getMemorySnapshot('get_memory_snapshot'),

  /// Save a named memory snapshot for later comparison.
  saveSnapshot('save_snapshot'),

  /// Compare two saved memory snapshots to find growth or leaks.
  compareSnapshots('compare_snapshots'),

  /// List all saved memory snapshots.
  listSnapshots('list_snapshots', requiresConnection: false),

  /// Audit class instances to find potential memory leaks.
  auditClassMemoryLeak('audit_class_memory_leak'),

  /// Track delta of heap allocations over a period of time.
  diffHeapAllocations('diff_heap_allocations'),

  /// Trace the retaining path keeping an object alive in memory.
  getObjectReferrers('get_object_referrers'),

  /// Read the current HTTP network requests profile history from the VM.
  getNetworkProfile('get_network_profile'),

  /// Start capturing HTTP traffic details statefully.
  startNetworkCapture('start_network_capture'),

  /// Stop capturing HTTP traffic and return the details report.
  stopNetworkCapture('stop_network_capture'),

  /// Check frame times to find rendering slowdowns (jank).
  diagnoseJank('diagnose_jank'),

  /// Sample CPU usage and find execution hotspots in Dart functions.
  getCpuProfile('get_cpu_profile'),

  /// Start a stateful CPU profiling session.
  startProfiling('start_profiling'),

  /// Stop the stateful CPU profiling session and get the CPU profile.
  stopProfiling('stop_profiling'),

  /// Trigger a hot reload on the running application.
  hotReload('hot_reload'),

  /// Trigger a hot restart on the running application.
  hotRestart('hot_restart'),

  /// Analyze build size details from size mapping files in the build/ directory.
  analyzeBundleSize('analyze_bundle_size', requiresConnection: false),

  /// Compare two screenshots and check for visual differences.
  compareLayoutScreenshots('compare_layout_screenshots'),

  /// Take a screenshot of the running application.
  takeScreenshot('take_screenshot'),

  /// Find widgets that rebuild frequently by tracking rebuild counts.
  getWidgetRebuildCounts('get_widget_rebuild_counts'),

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

  /// Start tracking widget rebuild counts.
  startTrackingRebuilds('start_tracking_rebuilds'),

  /// Stop tracking widget rebuild counts.
  stopTrackingRebuilds('stop_tracking_rebuilds'),

  /// Trigger a scroll gesture on the running application.
  triggerScrollGesture('trigger_scroll_gesture');

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
