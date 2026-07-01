import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import 'package:path/path.dart' as p;
import '../enums/flutter_debug_flag.dart';
import '../enums/mcp_tool.dart';
import '../extensions/call_tool_request_x.dart';
import 'vm_connection_support.dart';

/// Support mixin providing tools for widget inspection, layout diagnostics, and rebuild tracking.
base mixin WidgetInspectionSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Whether a rebuild tracking session is currently active.
  bool isTrackingRebuilds = false;

  /// Timestamp in milliseconds when rebuild tracking was started.
  int? rebuildStartTime;

  /// Cache mapping widget location IDs to rebuild counts.
  final Map<String, int> rebuildCounts = {};

  /// Cache mapping widget location IDs to display names.
  final Map<String, String> rebuildIdToName = {};

  /// Cache mapping widget location IDs to source file locations.
  final Map<String, String> rebuildIdToFile = {};

  /// Subscription to the VM Service's extension event stream for rebuilt widgets.
  StreamSubscription<Event>? rebuildSub;

  /// Registers all widget inspection and diagnostic tools.
  void registerWidgetTools() {

    registerTool(
      Tool(
        name: McpTool.getWidgetRebuildCounts.name,
        description:
            'Find widgets that rebuild frequently by tracking rebuild counts.',
        inputSchema: ObjectSchema(
          properties: {
            'duration_seconds': durationSchema(),
            'format': formatSchema,
          },
        ),
      ),
      _handleWidgetRebuildCounts,
    );

    registerTool(
      Tool(
        name: McpTool.inspectWidget.name,
        description:
            'Retrieve layout constraints and details of a widget by its ID.',
        inputSchema: ObjectSchema(
          properties: {
            'widgetId': StringSchema(
              description: 'The unique widget details ID.',
            ),
            'includeRawNode': BooleanSchema(
              description:
                  'Whether to include the full raw widget node representation in the structured data (default: false).',
            ),
            'format': formatSchema,
          },
          required: ['widgetId'],
        ),
      ),
      _handleInspectLayoutConstraints,
    );

    registerTool(
      Tool(
        name: McpTool.toggleWidgetSelection.name,
        description: 'Toggle the tap-to-select widget inspection overlay.',
        inputSchema: ObjectSchema(
          properties: {
            'enabled': BooleanSchema(
              description: 'Whether to enable the widget selection overlay.',
            ),
          },
          required: ['enabled'],
        ),
      ),
      _handleToggleWidgetSelection,
    );

    registerTool(
      Tool(
        name: McpTool.togglePackageWidgets.name,
        description:
            'Toggle whether package widgets are shown in the widget tree.',
        inputSchema: ObjectSchema(
          properties: {
            'enabled': BooleanSchema(
              description: 'Whether to enable showing package widgets.',
            ),
          },
          required: ['enabled'],
        ),
      ),
      _handleTogglePackageWidgets,
    );

    registerTool(
      Tool(
        name: McpTool.toggleDebugFlag.name,
        description:
            'Toggle standard Flutter debug paint/overlay flags (e.g. debugPaintSizeEnabled, debugPaintBaselinesEnabled).',
        inputSchema: ObjectSchema(
          properties: {
            'flag_name': StringSchema(
              description:
                  'Flag name: debugPaintSizeEnabled, debugPaintBaselinesEnabled, repaintRainbow, invertOversizedImages, timeDilation.',
            ),
            'value': StringSchema(
              description:
                  'Value to set: "true"/"false" or number string for timeDilation.',
            ),
          },
          required: ['flag_name', 'value'],
        ),
      ),
      _handleToggleDebugFlag,
    );

    registerTool(
      Tool(
        name: McpTool.getWidgetTree.name,
        description:
            'Get the current widget tree of the running Flutter application.',
        inputSchema: ObjectSchema(
          properties: {
            'maxDepth': NumberSchema(
              description:
                  'Maximum depth of the widget tree to return (default: 15).',
            ),
            'projectOnly': BooleanSchema(
              description:
                  'If true, only return widgets created by the local project code.',
            ),
            'format': formatSchema,
          },
        ),
      ),
      _handleGetWidgetTree,
    );

    registerTool(
      Tool(
        name: McpTool.startTrackingRebuilds.name,
        description:
            'Start a stateful session to track widget rebuild frequencies.',
        inputSchema: emptySchema(),
      ),
      _handleStartTrackingRebuilds,
    );

    registerTool(
      Tool(
        name: McpTool.stopTrackingRebuilds.name,
        description:
            'Stop the active widget rebuild tracking session and get the report.',
        inputSchema: ObjectSchema(
          properties: {
            'topN': NumberSchema(
              description:
                  'Number of top rebuilding widgets to list (default: 30).',
            ),
            'format': formatSchema,
          },
        ),
      ),
      _handleStopTrackingRebuilds,
    );

    registerTool(
      Tool(
        name: McpTool.triggerScrollGesture.name,
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
  }

  /// Clears active rebuild tracking listeners and cached state.
  void cleanupWidgetInspection() {
    rebuildSub?.cancel();
    rebuildSub = null;
    isTrackingRebuilds = false;
    rebuildCounts.clear();
    rebuildIdToName.clear();
    rebuildIdToFile.clear();
  }

  /// Handles the get_widget_rebuild_counts tool request.
  Future<CallToolResult> _handleWidgetRebuildCounts(CallToolRequest req) async {
    final duration = (req.arg<num>('duration_seconds'))?.toInt() ?? 3;
    stderr.writeln(
        '[mcp:widget_rebuild_counts] Starting rebuild tracking, duration=${duration}s');

    if (!await _isTrackRebuildSupported()) {
      stderr.writeln(
          '[mcp:widget_rebuild_counts] trackRebuildDirtyWidgets NOT available');
      return CallToolResult(
        content: [
          TextContent(
            text: 'Widget rebuild tracking is not available.\n'
                'This extension requires a debug-mode Flutter app.',
          )
        ],
        isError: true,
      );
    }

    final idToName = <String, String>{};
    final idToFile = <String, String>{};

    stderr.writeln(
        '[mcp:widget_rebuild_counts] Enabling trackRebuildDirtyWidgets...');
    await _enableRebuildTracking(idToName, idToFile);

    final rebuildEvents = <Map<String, dynamic>>[];
    final extSub = vmService!.onExtensionEvent.listen((Event event) {
      if (event.extensionKind == 'Flutter.RebuiltWidgets') {
        final data = event.extensionData?.data;
        if (data != null) {
          rebuildEvents.add(Map<String, dynamic>.from(data));
        }
      }
    });

    try {
      stderr.writeln(
          '[mcp:widget_rebuild_counts] Collecting rebuild events for ${duration}s...');
      await Future.delayed(Duration(seconds: duration));
    } finally {
      await extSub.cancel();
      try {
        await vmService!.callServiceExtension(
          'ext.flutter.inspector.trackRebuildDirtyWidgets',
          isolateId: isolateId,
          args: {'enabled': 'false'},
        );
      } catch (e) {
        stderr.writeln(
            '[mcp:widget_rebuild_counts] Error disabling trackRebuildDirtyWidgets: $e');
      }
    }

    stderr.writeln(
        '[mcp:widget_rebuild_counts] Collected ${rebuildEvents.length} rebuild events');

    final widgetCounts = <String, int>{};
    for (final event in rebuildEvents) {
      _parseLocationsMap(event['locations'], idToName, idToFile);
      _parseNewLocationsMap(event['newLocations'], idToFile);

      final events = event['events'] as List<dynamic>?;
      if (events != null) {
        for (var i = 0; i + 1 < events.length; i += 2) {
          final locId = events[i].toString();
          final count = events[i + 1] is int ? events[i + 1] as int : 1;
          widgetCounts[locId] = (widgetCounts[locId] ?? 0) + count;
        }
      }
    }

    stderr.writeln(
        '[mcp:widget_rebuild_counts] Location map: ${idToName.length} named, ${idToFile.length} with files');

    final widgets = <Map<String, dynamic>>[];
    widgetCounts.forEach((locId, count) {
      final name = idToName[locId] ?? 'Widget#$locId';
      final rawFile = idToFile[locId] ?? 'unknown';
      final resolvedPath = pathResolver != null
          ? pathResolver!.resolveToAbsolutePath(rawFile)
          : rawFile;
      widgets.add({
        'widget': name,
        'count': count,
        'location': resolvedPath,
        'id': locId,
      });
    });

    widgets.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

    final mdBuffer = StringBuffer('Top Rebuilding Widgets\n\n');
    if (widgets.isEmpty) {
      mdBuffer.writeln(
          'No rebuilds captured. Make sure you interacted with the app while tracking.');
    } else {
      mdBuffer.writeln('| Widget | Count | Location |');
      mdBuffer.writeln('| :--- | :--- | :--- |');
      for (final w in widgets) {
        mdBuffer.writeln(
            '| `${w['widget']}` | `${w['count']}x` | `${w['location']}` |');
      }
    }

    return serializeDualFormat(
      title: 'Widget Rebuilt Counts Analysis',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'widgets': widgets,
      },
      format: req.arg<String>('format'),
    );
  }

  /// Handles the inspect_widget tool request.
  Future<CallToolResult> _handleInspectLayoutConstraints(
      CallToolRequest req) async {
    final widgetId = req.requireArg<String>('widgetId');
    stderr.writeln('[mcp:inspect_layout] Inspecting widget: $widgetId');

    final response = await vmService!.callServiceExtension(
      'ext.flutter.inspector.getDetailsSubtree',
      isolateId: isolateId,
      args: {
        'id': widgetId,
        'arg': widgetId,
        'objectGroup': 'widget_inspector_group',
        'subtreeDepth': '2',
      },
    );

    final rawResult = response.json?['result'];
    Map<String, dynamic> result;
    if (rawResult is String) {
      result = jsonDecode(rawResult) as Map<String, dynamic>;
    } else if (rawResult is Map) {
      result = Map<String, dynamic>.from(rawResult);
    } else {
      result = {};
    }

    String? constraints;
    String? size;
    final properties = <String, String>{};

    void extract(Map<String, dynamic> node) {
      final props = node['properties'] as List<dynamic>?;
      if (props != null) {
        for (final prop in props) {
          if (prop is Map<String, dynamic>) {
            final name = prop['name']?.toString();
            final desc = prop['description']?.toString();
            if (name != null && desc != null) {
              properties[name] = desc;
              if (name == 'constraints') {
                constraints = desc;
              } else if (name == 'size') {
                size = desc;
              }
            }
          }
        }
      }
      final children = node['children'] as List<dynamic>?;
      if (children != null) {
        for (final child in children) {
          if (child is Map<String, dynamic>) {
            extract(child);
          }
        }
      }
    }

    extract(result);

    final md = StringBuffer('Layout Constraints for Widget: $widgetId\n\n');
    md.writeln('- Widget Type: ${result['description'] ?? 'Unknown'}');
    md.writeln('- Constraints: ${constraints ?? 'Not found'}');
    md.writeln('- Size: ${size ?? 'Not found'}');
    md.writeln('\nDiagnostic Properties');
    if (properties.isEmpty) {
      md.writeln('No properties found.');
    } else {
      md.writeln('| Property | Value |');
      md.writeln('| :--- | :--- |');
      properties.forEach((k, v) {
        md.writeln('| $k | `$v` |');
      });
    }

    final includeRawNode = req.arg<bool>('includeRawNode') ?? false;
    return serializeDualFormat(
      title: 'Layout Diagnostics Report',
      markdownBody: md.toString(),
      structuredData: {
        'widget_id': widgetId,
        'description': result['description'] ?? 'Unknown',
        'constraints': constraints,
        'size': size,
        'all_properties': properties,
        if (includeRawNode) 'raw_node': result,
      },
      format: req.arg<String>('format'),
    );
  }

  /// Handles the toggle_widget_selection tool request.
  Future<CallToolResult> _handleToggleWidgetSelection(
      CallToolRequest req) async {
    final enabled = req.requireArg<bool>('enabled');
    stderr.writeln('[mcp:toggle_widget_selection] Setting enabled = $enabled');

    await vmService!.callServiceExtension(
      'ext.flutter.inspector.show',
      isolateId: isolateId,
      args: {'enabled': enabled ? 'true' : 'false'},
    );
    return CallToolResult(
      content: [
        TextContent(
            text:
                'On-device widget selection overlay is now ${enabled ? "enabled" : "disabled"}.')
      ],
    );
  }

  /// Handles the toggle_package_widgets tool request.
  Future<CallToolResult> _handleTogglePackageWidgets(
      CallToolRequest req) async {
    final enabled = req.requireArg<bool>('enabled');
    stderr.writeln('[mcp:toggle_package_widgets] Setting enabled = $enabled');

    final root = workspaceRoot;
    if (root == null || root.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'Workspace root is not configured. Please reconnect to the app specifying workspace_root.',
          ),
        ],
        isError: true,
      );
    }

    final packagePaths = _getPackageDirectories(root);
    if (packagePaths.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'No packages found in package_config.json or file does not exist at $root/.dart_tool/package_config.json',
          ),
        ],
        isError: true,
      );
    }

    if (!packagePaths.contains(root)) {
      packagePaths.insert(0, root);
    }

    final isolate = await vmService!.getIsolate(isolateId!);
    final libraries = isolate.libraries ?? [];
    LibraryRef? widgetInspectorLib;
    for (final lib in libraries) {
      if (lib.uri == 'package:flutter/src/widgets/widget_inspector.dart') {
        widgetInspectorLib = lib;
        break;
      }
    }

    if (widgetInspectorLib == null || widgetInspectorLib.id == null) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'WidgetInspectorService library not found in target isolate. Make sure the app is running in debug mode.',
          ),
        ],
        isError: true,
      );
    }

    final libId = widgetInspectorLib.id!;
    final pathsLiteral = packagePaths
        .map((p) => "'${p.replaceAll("'", "\\'")}'")
        .toList()
        .toString();

    if (enabled) {
      stderr.writeln(
          '[mcp:toggle_package_widgets] Adding ${packagePaths.length} pub root directories');
      await vmService!.evaluate(
        isolateId!,
        libId,
        'WidgetInspectorService.instance.addPubRootDirectories($pathsLiteral)',
      );
    } else {
      stderr.writeln(
          '[mcp:toggle_package_widgets] Removing ${packagePaths.length} pub root directories');
      await vmService!.evaluate(
        isolateId!,
        libId,
        'WidgetInspectorService.instance.removePubRootDirectories($pathsLiteral)',
      );
    }

    var currentDirs = 'unknown';
    try {
      final res = await vmService!.evaluate(
        isolateId!,
        libId,
        'WidgetInspectorService.instance.pubRootDirectories',
      );
      if (res is InstanceRef) {
        currentDirs = res.valueAsString ?? res.toString();
      } else {
        currentDirs = res.toString();
      }
    } catch (e) {
      stderr.writeln('[mcp:widget] Error fetching pubRootDirectories: $e');
    }

    return CallToolResult(
      content: [
        TextContent(
          text:
              'Successfully ${enabled ? "enabled" : "disabled"} package widgets in the inspector.\n'
              '- Configured directories: ${packagePaths.length}\n'
              '- Current pub root directories: $currentDirs',
        ),
      ],
    );
  }

  List<String> _getPackageDirectories(String workspaceRoot) {
    final directories = <String>[];
    final configPath =
        p.join(workspaceRoot, '.dart_tool', 'package_config.json');
    final file = File(configPath);
    if (!file.existsSync()) {
      stderr.writeln(
          '[mcp:package_resolver] package_config.json not found at $configPath');
      return directories;
    }

    final json = jsonDecode(file.readAsStringSync());
    final packages = json['packages'] as List<dynamic>?;
    if (packages == null) return directories;

    final configDir = Directory(p.dirname(configPath));

    for (final package in packages) {
      if (package is! Map) continue;
      final rootUriStr = package['rootUri'] as String?;
      if (rootUriStr == null) continue;

      var uri = Uri.parse(rootUriStr);
      if (!uri.isAbsolute) {
        final absolutePath =
            p.canonicalize(p.join(configDir.path, uri.toFilePath()));
        directories.add(absolutePath);
      } else if (uri.scheme == 'file') {
        directories.add(p.canonicalize(uri.toFilePath()));
      }
    }

    return directories;
  }

  /// Handles the toggle_debug_flag tool request.
  Future<CallToolResult> _handleToggleDebugFlag(CallToolRequest req) async {
    final flagNameInput = req.requireArg<String>('flag_name');
    final value = req.requireArg<String>('value');
    final flag = FlutterDebugFlag.fromString(flagNameInput);
    stderr.writeln(
        '[mcp:toggle_debug_flag] Resolved flag $flagNameInput to ${flag.flagName}, setting to value=$value');

    final extensionName = 'ext.flutter.${flag.extensionSuffix}';
    final Map<String, dynamic> args;
    if (flag == FlutterDebugFlag.timeDilation) {
      final doubleVal = double.tryParse(value) ?? 1.0;
      args = {'timeDilation': doubleVal.toString()};
    } else {
      final boolVal = value == 'true';
      args = {'enabled': boolVal ? 'true' : 'false'};
    }

    await vmService!.callServiceExtension(
      extensionName,
      isolateId: isolateId,
      args: args,
    );

    return CallToolResult(
      content: [
        TextContent(
            text: 'Successfully set debug flag `${flag.flagName}` to `$value`.')
      ],
    );
  }

  /// Handles the get_widget_tree tool request.
  Future<CallToolResult> _handleGetWidgetTree(CallToolRequest req) async {
    final maxDepth = (req.arg<num>('maxDepth'))?.toInt() ?? 15;
    final projectOnly = req.arg<bool>('projectOnly') ?? false;

    final objectGroup =
        'mcp_inspector_${DateTime.now().millisecondsSinceEpoch}';

    dynamic rootNode;
    try {
      final response = await vmService!.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetSummaryTree',
        isolateId: isolateId,
        args: {'objectGroup': objectGroup},
      );
      rootNode = _parseExtensionResult(response);
    } catch (e) {
      final response = await vmService!.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetTree',
        isolateId: isolateId,
        args: {
          'groupName': objectGroup,
          'isSummaryTree': 'true',
          'withPreviews': 'false',
        },
      );
      rootNode = _parseExtensionResult(response);
    }

    if (rootNode == null) {
      return CallToolResult(
        content: [TextContent(text: 'Failed to retrieve root widget node.')],
        isError: true,
      );
    }

    final Map<String, dynamic> rootMap;
    if (rootNode is Map) {
      rootMap = Map<String, dynamic>.from(rootNode);
    } else {
      return CallToolResult(
        content: [
          TextContent(text: 'Unexpected response format for root widget node.')
        ],
        isError: true,
      );
    }

    await _expandWidgetChildren(rootMap, objectGroup, 0, maxDepth);

    final flattened = _flattenWidgetTree(rootMap, 0, maxDepth, projectOnly);
    final text = _formatTreeAsText(flattened);

    final totalWidgets = flattened.length;
    final projectWidgets = flattened.where((w) => w.isProjectWidget).length;
    final maxDepthReached = flattened.isEmpty
        ? 0
        : flattened.map((w) => w.depth).reduce((a, b) => a > b ? a : b);

    return serializeDualFormat(
      title: 'Widget Tree Summary',
      markdownBody:
          'Widget Tree ($totalWidgets widgets, $projectWidgets from project, depth: $maxDepthReached)\n\n$text',
      structuredData: {
        'total_widgets': totalWidgets,
        'project_widgets': projectWidgets,
        'max_depth_reached': maxDepthReached,
        'widgets': flattened.map((w) => w.toMap()).toList(),
      },
      format: req.arg<String>('format'),
    );
  }

  dynamic _parseExtensionResult(Response response) {
    final result = response.json?['result'];
    if (result is String) {
      return jsonDecode(result);
    }
    return result;
  }

  Future<void> _expandWidgetChildren(
    Map<String, dynamic> node,
    String objectGroup,
    int depth,
    int maxDepth,
  ) async {
    if (depth >= maxDepth) return;

    final hasChildren = node['hasChildren'] as bool? ?? false;
    var childrenList = node['children'] as List<dynamic>?;

    if (hasChildren && (childrenList == null || childrenList.isEmpty)) {
      final valueId = node['valueId'] as String?;
      if (valueId != null) {
        try {
          final response = await vmService!.callServiceExtension(
            'ext.flutter.inspector.getChildrenSummaryTree',
            isolateId: isolateId,
            args: {
              'arg': valueId,
              'objectGroup': objectGroup,
            },
          );
          final result = _parseExtensionResult(response);
          if (result is List) {
            node['children'] = result;
            childrenList = result;
          }
        } catch (e) {
          stderr.writeln(
              '[mcp:widget] Error resolving child details subtree: $e');
        }
      }
    }

    if (childrenList != null) {
      for (var i = 0; i < childrenList.length; i++) {
        final child = childrenList[i];
        if (child is Map) {
          final childMap = Map<String, dynamic>.from(child);
          childrenList[i] = childMap;
          await _expandWidgetChildren(
              childMap, objectGroup, depth + 1, maxDepth);
        }
      }
    }
  }

  List<_FlatWidget> _flattenWidgetTree(
    Map<String, dynamic> node,
    int depth,
    int maxDepth,
    bool projectOnly,
  ) {
    if (depth > maxDepth) return [];

    final isProjectWidget = node['createdByLocalProject'] as bool? ?? false;
    final children = node['children'] as List<dynamic>? ?? [];

    if (projectOnly && !isProjectWidget && depth > 2) {
      final childResults = <_FlatWidget>[];
      for (final child in children) {
        if (child is Map) {
          childResults.addAll(
            _flattenWidgetTree(
                Map<String, dynamic>.from(child), depth, maxDepth, projectOnly),
          );
        }
      }
      return childResults;
    }

    final creationLocation = node['creationLocation'] as Map<dynamic, dynamic>?;
    final creationName = creationLocation?['name'] as String?;
    final widgetRuntimeType = node['widgetRuntimeType'] as String?;
    final description = node['description'] as String?;
    final typeStr = node['type'] as String?;

    final widgetName = creationName ??
        widgetRuntimeType ??
        description ??
        typeStr ??
        'Unknown';

    final (sourceFile, sourceLine) = (isProjectWidget && creationLocation != null)
        ? _extractSourceLocation(creationLocation)
        : (null, null);

    final rawProperties = node['properties'] as List<dynamic>?;
    List<Map<String, String>>? properties;
    if (rawProperties != null && rawProperties.isNotEmpty) {
      properties = [];
      for (final prop in rawProperties) {
        if (prop is Map) {
          final propName = prop['name']?.toString();
          final propDesc =
              prop['description']?.toString() ?? prop['value']?.toString();
          if (propName != null && propDesc != null && propDesc != 'null') {
            properties.add({
              'name': propName,
              'value': propDesc,
            });
          }
        }
      }
      if (properties.length > 10) {
        properties = properties.sublist(0, 10);
      }
    }

    final flat = _FlatWidget(
      type: widgetName,
      depth: depth,
      id: node['valueId'] as String?,
      isProjectWidget: isProjectWidget,
      childCount: children.length,
      sourceFile: sourceFile,
      sourceLine: sourceLine,
      properties: properties,
    );

    final results = [flat];
    for (final child in children) {
      if (child is Map) {
        results.addAll(
          _flattenWidgetTree(Map<String, dynamic>.from(child), depth + 1,
              maxDepth, projectOnly),
        );
      }
    }

    return results;
  }

  String _formatTreeAsText(List<_FlatWidget> widgets) {
    final buffer = StringBuffer();
    for (final w in widgets) {
      final indent = '  ' * w.depth;
      final projectMarker = w.isProjectWidget ? ' *' : '';
      final childInfo = w.childCount > 0 ? ' (${w.childCount} children)' : '';
      final sourceInfo =
          w.sourceFile != null ? ' [${w.sourceFile}:${w.sourceLine}]' : '';

      buffer.write('$indent${w.type}$projectMarker$childInfo$sourceInfo');

      final props = w.properties;
      if (props != null && props.isNotEmpty) {
        final propsStr =
            props.map((p) => '${p['name']}: ${p['value']}').join(', ');
        buffer.write(' [$propsStr]');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// Handles the start_tracking_rebuilds tool request.
  Future<CallToolResult> _handleStartTrackingRebuilds(
      CallToolRequest req) async {
    if (isTrackingRebuilds) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Already tracking rebuilds. Call stop_tracking_rebuilds first.')
        ],
        isError: true,
      );
    }

    stderr.writeln(
        '[mcp:widget_rebuild_counts] Starting rebuild tracking session...');

    if (!await _isTrackRebuildSupported()) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'Widget rebuild tracking is not available.\n'
                'This extension requires a debug-mode Flutter app.',
          )
        ],
        isError: true,
      );
    }

    isTrackingRebuilds = true;
    rebuildStartTime = DateTime.now().millisecondsSinceEpoch;
    rebuildCounts.clear();
    rebuildIdToName.clear();
    rebuildIdToFile.clear();

    await _enableRebuildTracking(rebuildIdToName, rebuildIdToFile);

    rebuildSub = vmService!.onExtensionEvent.listen((Event event) {
      if (event.extensionKind == 'Flutter.RebuiltWidgets') {
        final data = event.extensionData?.data;
        if (data != null) {
          _parseLocationsMap(
              data['locations'], rebuildIdToName, rebuildIdToFile);
          _parseNewLocationsMap(data['newLocations'], rebuildIdToFile);

          final events = data['events'] as List<dynamic>?;
          if (events != null) {
            for (var i = 0; i + 1 < events.length; i += 2) {
              final locId = events[i].toString();
              final count = events[i + 1] is int ? events[i + 1] as int : 1;
              rebuildCounts[locId] = (rebuildCounts[locId] ?? 0) + count;
            }
          }
        }
      }
    });

    return CallToolResult(
      content: [
        TextContent(
          text:
              'Rebuild tracking started. Interact with the app now, then call `stop_tracking_rebuilds` to see the report.',
        )
      ],
    );
  }

  /// Handles the stop_tracking_rebuilds tool request.
  Future<CallToolResult> _handleStopTrackingRebuilds(
      CallToolRequest req) async {
    if (!isTrackingRebuilds) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Not tracking rebuilds. Call start_tracking_rebuilds first.')
        ],
        isError: true,
      );
    }

    final topN = (req.arg<num>('topN'))?.toInt() ?? 30;

    stderr.writeln(
        '[mcp:widget_rebuild_counts] Stopping rebuild tracking session...');
    isTrackingRebuilds = false;
    await rebuildSub?.cancel();
    rebuildSub = null;

    await vmService!.callServiceExtension(
      'ext.flutter.inspector.trackRebuildDirtyWidgets',
      isolateId: isolateId,
      args: {'enabled': 'false'},
    );

    final durationSec = rebuildStartTime != null
        ? ((DateTime.now().millisecondsSinceEpoch - rebuildStartTime!) / 1000.0)
            .toStringAsFixed(1)
        : 'unknown';

    try {
      final locationResponse = await vmService!.callServiceExtension(
        'ext.flutter.inspector.widgetLocationIdMap',
        isolateId: isolateId,
      );
      final rawLocationResult = locationResponse.json?['result'];
      if (rawLocationResult is String) {
        final decoded = jsonDecode(rawLocationResult);
        _parseLocationsMap(decoded, rebuildIdToName, rebuildIdToFile);
      } else if (rawLocationResult is Map) {
        _parseLocationsMap(rawLocationResult, rebuildIdToName, rebuildIdToFile);
      }
    } catch (e) {
      stderr.writeln('[mcp:widget] Error fetching widget location ID map: $e');
    }

    final widgets = <Map<String, dynamic>>[];
    var totalRebuilds = 0;

    rebuildCounts.forEach((locId, count) {
      totalRebuilds += count;
      final name = rebuildIdToName[locId] ?? 'Widget#$locId';
      final rawFile = rebuildIdToFile[locId] ?? 'unknown';
      final resolvedPath = pathResolver != null
          ? pathResolver!.resolveToAbsolutePath(rawFile)
          : rawFile;
      widgets.add({
        'widget': name,
        'count': count,
        'location': resolvedPath,
        'id': locId,
      });
    });

    widgets.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

    final output = [
      'WIDGET REBUILD REPORT',
      '',
      'SUMMARY',
      'Tracked for ${durationSec}s',
      'Total rebuilds: $totalRebuilds',
      'Unique widgets rebuilt: ${widgets.length}',
      '',
    ];

    if (widgets.isEmpty) {
      output.add(
          'No rebuilds captured. Make sure you interacted with the app while tracking.');
    } else {
      output.add(
          'TOP ${widgets.length < topN ? widgets.length : topN} REBUILDING WIDGETS');
      String getShortFile(String fileLoc) {
        final pathParts = p.split(fileLoc);
        final libIdx = pathParts.indexOf('lib');
        if (libIdx != -1) {
          return p.joinAll(pathParts.sublist(libIdx));
        }
        return p.basename(fileLoc);
      }

      for (final w in widgets.take(topN)) {
        final count = w['count'] as int;
        final name = w['widget'] as String;
        final fileLoc = w['location'] as String;
        final shortFile = getShortFile(fileLoc);
        final severity = count > 100
            ? '[HIGH]'
            : count > 30
                ? '[MEDIUM]'
                : count > 10
                    ? '[LOW]'
                    : '[OK]';
        output.add('$severity ${count}x | $name [$shortFile]');
      }

      final excessive = widgets.where((w) => (w['count'] as int) > 50).toList();
      if (excessive.isNotEmpty) {
        output.add('');
        output.add('RECOMMENDATIONS');
        for (final w in excessive.take(5)) {
          final count = w['count'] as int;
          final name = w['widget'] as String;
          final fileLoc = w['location'] as String;
          final shortFile = getShortFile(fileLoc);
          output.add('- $name rebuilt ${count}x [$shortFile]');
          if (count > 100) {
            output.add(
                '  -> Wrap in a const constructor, or extract to limit rebuild scope.');
          } else {
            output.add(
                '  -> Consider optimizing state dependencies or using context.select().');
          }
        }
      }
    }

    return serializeDualFormat(
      title: 'Widget Rebuild Analysis',
      markdownBody: output.join('\n'),
      structuredData: {
        'duration_seconds': double.tryParse(durationSec) ?? 0.0,
        'total_recorded_widgets': widgets.length,
        'total_rebuilds': totalRebuilds,
        'rebuilds': widgets.take(topN).toList(),
      },
      format: req.arg<String>('format'),
    );
  }

  void _parseLocationsMap(
    dynamic locationsObj,
    Map<String, String> idToName,
    Map<String, String> idToFile,
  ) {
    if (locationsObj is! Map) return;
    locationsObj.forEach((key, value) {
      final filePath = key.toString();
      if (value is Map) {
        final ids = value['ids'];
        final lines = value['lines'];
        final names = value['names'];
        if (ids is List) {
          for (var i = 0; i < ids.length; i++) {
            final id = ids[i].toString();
            final line =
                (lines is List && i < lines.length) ? lines[i].toString() : '?';
            final name = (names is List && i < names.length && names[i] != null)
                ? names[i].toString()
                : null;
            if (name != null && name.isNotEmpty) {
              idToName[id] = name;
            }
            idToFile[id] = '$filePath:$line';
          }
        }
      }
    });
  }

  void _parseNewLocationsMap(
    dynamic newLocationsObj,
    Map<String, String> idToFile,
  ) {
    if (newLocationsObj is! Map) return;
    newLocationsObj.forEach((key, value) {
      final filePath = key.toString();
      if (value is List) {
        for (var i = 0; i + 2 < value.length; i += 3) {
          final id = value[i].toString();
          final line = value[i + 1].toString();
          idToFile.putIfAbsent(id, () => '$filePath:$line');
        }
      }
    });
  }

  /// Handles the trigger_scroll_gesture tool request.
  Future<CallToolResult> _handleScrollGesture(CallToolRequest req) async {
    final controller = req.requireArg<String>('scroll_controller_expression');
    final offset = (req.arg<num>('offset'))?.toDouble() ?? 500.0;
    stderr.writeln(
        '[mcp:scroll_gesture] Controller: $controller, offset: $offset');

    final script = '$controller.animateTo('
        '$offset,'
        'duration: const Duration(milliseconds: 300),'
        'curve: Curves.easeInOut,'
        ')';

    final libraryId = await getEvaluationLibraryId();
    final eval = await vmService!.evaluate(isolateId!, libraryId, script);
    final evalStr = eval is InstanceRef ? eval.valueAsString : eval.toString();
    return CallToolResult(
      content: [
        TextContent(
            text:
                'Scroll gesture driven successfully. Evaluation result: `$evalStr`')
      ],
    );
  }

  Future<bool> _isTrackRebuildSupported() async {
    final isolate = await vmService!.getIsolate(isolateId!);
    final extensions = isolate.extensionRPCs ?? [];
    return extensions
        .contains('ext.flutter.inspector.trackRebuildDirtyWidgets');
  }

  Future<void> _enableRebuildTracking(
    Map<String, String> idToName,
    Map<String, String> idToFile,
  ) async {
    await vmService!.callServiceExtension(
      'ext.flutter.inspector.trackRebuildDirtyWidgets',
      isolateId: isolateId,
      args: {'enabled': 'true'},
    );
    try {
      final locationResponse = await vmService!.callServiceExtension(
        'ext.flutter.inspector.widgetLocationIdMap',
        isolateId: isolateId,
      );
      final rawLocationResult = locationResponse.json?['result'];
      if (rawLocationResult is String) {
        final decoded = jsonDecode(rawLocationResult);
        _parseLocationsMap(decoded, idToName, idToFile);
      } else if (rawLocationResult is Map) {
        _parseLocationsMap(rawLocationResult, idToName, idToFile);
      }
    } catch (e) {
      stderr.writeln(
          '[mcp:widget] Error enabling rebuild tracking locations: $e');
    }
    try {
      await vmService!.streamListen(EventStreams.kExtension);
    } catch (e) {
      stderr.writeln('[mcp:widget] Error listening to extension stream: $e');
    }
  }

  /// Extracts project source location (file path and line number) from a creation location map.
  (String? file, int? line) _extractSourceLocation(Map<dynamic, dynamic> creationLocation) {
    String? sourceFile;
    final fileUri = creationLocation['file'] as String?;
    if (fileUri != null) {
      try {
        final cleanFile = Uri.parse(fileUri).toFilePath();
        final parts = p.split(cleanFile);
        final libIndex = parts.indexOf('lib');
        if (libIndex != -1) {
          sourceFile = p.joinAll(parts.sublist(libIndex));
        } else {
          sourceFile = p.basename(cleanFile);
        }
      } catch (_) {
        final cleanFile = fileUri.replaceFirst(RegExp(r'^file://'), '');
        final parts = cleanFile.split('/lib/');
        if (parts.length > 1) {
          sourceFile = parts.last;
        } else {
          sourceFile = cleanFile.split('/').last;
        }
      }
    }
    final sourceLine = creationLocation['line'] as int?;
    return (sourceFile, sourceLine);
  }
}

/// Represents a flattened, simplified widget node from the widget tree.
final class _FlatWidget {
  /// The class type/name of the widget.
  final String type;

  /// The depth level of the widget in the tree (0-indexed).
  final int depth;

  /// The unique value ID of the widget in the inspector service.
  final String? id;

  /// Whether the widget was created directly by the user's project codebase.
  final bool isProjectWidget;

  /// Total number of immediate children this widget has.
  final int childCount;

  /// The relative source file path where this widget is instantiated.
  final String? sourceFile;

  /// The 1-based source line number where this widget is instantiated.
  final int? sourceLine;

  /// Key-value properties of the widget extracted from diagnostic details.
  final List<Map<String, String>>? properties;

  /// Creates a new [_FlatWidget] data container.
  _FlatWidget({
    required this.type,
    required this.depth,
    this.id,
    required this.isProjectWidget,
    required this.childCount,
    this.sourceFile,
    this.sourceLine,
    this.properties,
  });

  /// Serializes the widget data into a Map.
  Map<String, dynamic> toMap() {
    return {
      'type': type,
      'depth': depth,
      if (id != null) 'id': id,
      'isProjectWidget': isProjectWidget,
      'childCount': childCount,
      if (sourceFile != null) 'sourceFile': sourceFile,
      if (sourceLine != null) 'sourceLine': sourceLine,
      if (properties != null) 'properties': properties,
    };
  }
}
