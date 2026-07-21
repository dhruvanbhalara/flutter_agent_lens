import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';

/// Support mixin providing tools for widget inspection, layout diagnostics, and widget tree retrieval.
base mixin WidgetInspectionSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers layout constraints and widget tree inspection tools.
  void registerWidgetTools() {
    registerTool(
      Tool(
        name: McpTool.widget.name,
        description:
            'Manage widget tree, inspect layout details, and toggle selection overlay. '
            'Actions: inspect (widget properties), toggle_selection (on-device tap-to-select overlay), '
            'get_tree (retrieve widget tree summary).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description:
                  'The widget action: inspect, toggle_selection, get_tree.',
            ),
            'widgetId': StringSchema(
              description:
                  'The unique widget details ID (required for action: inspect).',
            ),
            'includeRawNode': BooleanSchema(
              description:
                  'Whether to include the full raw widget node representation in structured data (default: false, for action: inspect).',
            ),
            'enabled': BooleanSchema(
              description:
                  'Whether to enable the widget selection overlay (required for action: toggle_selection).',
            ),
            'maxDepth': IntegerSchema(
              description:
                  'Maximum depth of the widget tree to return (default: 8, for action: get_tree).',
            ),
            'projectOnly': BooleanSchema(
              description:
                  'If true, only return widgets created by the local project code (default: true, for action: get_tree).',
            ),
          },
          required: ['action'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: false,
        ),
      ),
      _handleWidget,
    );

    registerTool(
      Tool(
        name: McpTool.getNavigationStack.name,
        description:
            "Retrieve the application's current routing/navigation stacks.",
        inputSchema: emptySchema(),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: true,
        ),
      ),
      _handleGetNavigationStack,
    );
  }

  /// Delegates widget actions to respective handlers.
  Future<CallToolResult> _handleWidget(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    return switch (action) {
      'inspect' => _handleInspectLayoutConstraints(req),
      'toggle_selection' => _handleToggleWidgetSelection(req),
      'get_tree' => _handleGetWidgetTree(req),
      _ => CallToolResult(
          content: [TextContent(text: 'Unknown widget action: $action')],
          isError: true,
        ),
    };
  }

  /// Clears active inspection cache.
  Future<void> cleanupWidgetInspection() async {}

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

  /// Handles the get_widget_tree tool request.
  Future<CallToolResult> _handleGetWidgetTree(CallToolRequest req) async {
    final maxDepth = (req.arg<num>('maxDepth'))?.toInt() ?? 8;
    final projectOnly = req.arg<bool>('projectOnly') ?? true;

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
      final futures = <Future<void>>[];
      for (var i = 0; i < childrenList.length; i++) {
        final child = childrenList[i];
        if (child is Map) {
          final childMap = Map<String, dynamic>.from(child);
          childrenList[i] = childMap;
          futures.add(_expandWidgetChildren(
              childMap, objectGroup, depth + 1, maxDepth));
        }
      }
      if (futures.isNotEmpty) {
        await Future.wait(futures);
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

    final (sourceFile, sourceLine) =
        (isProjectWidget && creationLocation != null)
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

  /// Extracts project source location (file path and line number) from a creation location map.
  (String? file, int? line) _extractSourceLocation(
      Map<dynamic, dynamic> creationLocation) {
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
        final cleanFile = fileUri.replaceFirst(RegExp('^file://'), '');
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

  /// Handles retrieving the navigation stack tree from the running application.
  Future<CallToolResult> _handleGetNavigationStack(CallToolRequest req) async {
    stderr.writeln('[mcp:get_navigation_stack] Retrieving navigation tree...');
    try {
      if (isolateId == null || vmService == null) {
        return CallToolResult(
          content: [TextContent(text: 'No active VM connection.')],
          isError: true,
        );
      }

      final isolate = await vmService!.getIsolate(isolateId!);
      if (isolate.libraries == null) {
        return CallToolResult(
          content: [TextContent(text: 'No libraries found in target isolate.')],
          isError: true,
        );
      }

      // Evaluate the navigation script inside 'navigator.dart' to access the private '_history' field.
      final navigatorLib = isolate.libraries!.firstWhere(
        (lib) => lib.uri == 'package:flutter/src/widgets/navigator.dart',
        orElse: () =>
            throw StateError('Navigator library not found in target isolate.'),
      );

      // 'navigator.dart' does not import 'widget_inspector.dart' so WidgetInspectorService is undefined there.
      // We resolve the WidgetInspectorService.instance ID in the inspector library, then pass it via 'scope'.
      final inspectorLib = isolate.libraries!.firstWhere(
        (lib) => lib.uri == 'package:flutter/src/widgets/widget_inspector.dart',
        orElse: () => navigatorLib,
      );

      String? inspectorServiceId;
      if (inspectorLib.id != null &&
          inspectorLib.uri ==
              'package:flutter/src/widgets/widget_inspector.dart') {
        try {
          final inspectorServiceEval = await vmService!.evaluate(
            isolateId!,
            inspectorLib.id!,
            'WidgetInspectorService.instance',
          );
          if (inspectorServiceEval is InstanceRef) {
            inspectorServiceId = inspectorServiceEval.id;
          }
        } catch (_) {}
      }

      final libId = navigatorLib.id;
      if (libId == null) {
        return CallToolResult(
          content: [TextContent(text: 'Navigator library ID is null.')],
          isError: true,
        );
      }

      final eval = await vmService!.evaluate(
        isolateId!,
        libId,
        _navigationStackScript.replaceAll('\n', ' ').replaceAll('\r', ' '),
        scope: inspectorServiceId != null
            ? {'inspectorService': inspectorServiceId}
            : null,
      );
      if (eval is! InstanceRef) {
        return CallToolResult(
          content: [
            TextContent(
                text:
                    'Evaluation failed. Unexpected result type: ${eval.runtimeType}')
          ],
          isError: true,
        );
      }

      var jsonStr = eval.valueAsString;
      if (eval.valueAsStringIsTruncated == true) {
        final fullObj = await vmService!.getObject(isolateId!, eval.id!);
        if (fullObj is Instance) {
          jsonStr = fullObj.valueAsString;
        }
      }
      if (jsonStr == null) {
        return CallToolResult(
          content: [TextContent(text: 'Evaluation result string is null.')],
          isError: true,
        );
      }

      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (decoded.containsKey('error')) {
        return CallToolResult(
          content: [
            TextContent(text: 'Navigation tree error: ${decoded['error']}')
          ],
          isError: true,
        );
      }

      final currentUrl = decoded['currentUrl'] as String?;
      final staticRouteTree = decoded['staticRouteTree'] as String?;
      final navRaw = decoded['navigators'] as List<dynamic>? ?? [];
      final delegates = decoded['delegates'] as List<dynamic>? ?? [];
      final evalLogs = decoded['logs'] as List<dynamic>? ?? [];
      stderr.writeln(
          '[mcp:get_navigation_stack] Found router delegates in tree: $delegates');
      stderr.writeln('[mcp:get_navigation_stack] Eval logs: $evalLogs');

      final navList = navRaw.cast<Map<String, dynamic>>().toList();
      final navMap = <int, Map<String, dynamic>>{};
      for (final nav in navList) {
        final id = nav['id'] as int?;
        if (id != null) {
          navMap[id] = nav;
        }
      }

      final md = StringBuffer();
      if (currentUrl != null) {
        md.writeln('Current URL: $currentUrl');
        md.writeln();
      }

      if (staticRouteTree != null && staticRouteTree.trim().isNotEmpty) {
        md.writeln('Static Route Tree:');
        md.writeln(staticRouteTree.trim());
        md.writeln();
      }

      int maxRouteCount = 0;

      void renderNav(int id, String indent, {required bool isLast}) {
        final nav = navMap[id];
        if (nav == null) return;

        final routes = nav['routes'] as List<dynamic>? ?? [];
        final parentId = nav['parentId'] as int?;
        final depth = routes.length;
        if (depth > maxRouteCount) maxRouteCount = depth;

        final label = parentId == null ? 'Navigator [root]' : 'Navigator';
        md.writeln('$indent$label ($depth routes)');

        final children = navList.where((n) => n['parentId'] == id).toList();
        final renderedChildren = <int>{};

        for (var i = 0; i < routes.length; i++) {
          final r = routes[i] as Map<String, dynamic>;
          var name = r['name'] as String? ?? 'anonymous';
          final screenName = r['screenName'] as String?;
          final routeHash = r['hash'] as int? ?? 0;
          final isCurrent = r['isCurrent'] == true;
          final isFirst = r['isFirst'] == true;
          final routeType = r['type'] as String? ?? '';

          bool isScrambled = false;
          if (name.length == 32) {
            isScrambled = true;
            for (final charCode in name.codeUnits) {
              if (charCode < 89 || charCode > 121) {
                isScrambled = false;
                break;
              }
            }
          }

          final isHashcode = RegExp(r'^\d+$').hasMatch(name);

          if (screenName != null) {
            if (name == 'anonymous' || isScrambled || isHashcode) {
              name = screenName;
            } else if (name != screenName) {
              name = '$name ($screenName)';
            }
          } else if (isScrambled) {
            name = 'GoRouter Shell (wrapper)';
          }

          final nestedChildren = children
              .where((n) => n['parentRouteHash'] == routeHash && routeHash != 0)
              .toList();

          final isLastRoute = i == routes.length - 1 &&
              children
                  .where((n) => !renderedChildren.contains(n['id'] as int))
                  .isEmpty;

          final branch = isLastRoute ? '$indent  └──' : '$indent  ├──';
          final tag = isCurrent ? ' [current]' : (isFirst ? ' [root]' : '');
          final cleanType =
              routeType.replaceAll('<dynamic>', '').replaceAll('<void>', '');
          final typeStr = (cleanType.isNotEmpty && cleanType != 'Route')
              ? ' ($cleanType)'
              : '';
          md.writeln('$branch $name$typeStr$tag');

          for (var ci = 0; ci < nestedChildren.length; ci++) {
            final childId = nestedChildren[ci]['id'] as int;
            renderedChildren.add(childId);
            final childIsLast = ci == nestedChildren.length - 1 && isLastRoute;
            renderNav(childId, '$indent      ', isLast: childIsLast);
          }
        }

        final remainingChildren = children
            .where((n) => !renderedChildren.contains(n['id'] as int))
            .toList();

        for (var ci = 0; ci < remainingChildren.length; ci++) {
          final childId = remainingChildren[ci]['id'] as int;
          final childIsLast = ci == remainingChildren.length - 1;
          renderNav(childId, '$indent      ', isLast: childIsLast);
        }
      }

      final roots = navList.where((n) => n['parentId'] == null).toList();

      if (roots.isEmpty && navList.isNotEmpty) {
        for (final n in navList) {
          renderNav(n['id'] as int, '', isLast: true);
        }
      } else {
        for (var i = 0; i < roots.length; i++) {
          renderNav(roots[i]['id'] as int, '', isLast: i == roots.length - 1);
        }
      }

      if (navList.isEmpty) {
        md.writeln('No active navigators found.');
      }

      md.writeln();
      final hasLeak = maxRouteCount >= 20;
      if (hasLeak) {
        md.writeln(
            'WARNING: Navigator stack depth $maxRouteCount exceeds limit of 20. Possible navigation leak.');
      } else {
        md.writeln('Max stack depth: $maxRouteCount/20. No leak detected.');
      }

      return serializeDualFormat(
        title: 'Navigation Tree',
        markdownBody: md.toString(),
        structuredData: {
          'current_url': currentUrl,
          'static_route_tree': staticRouteTree,
          'navigator_count': navList.length,
          'max_depth': maxRouteCount,
          'has_leak_warning': hasLeak,
          'navigators': navList,
          'delegates': delegates,
          'logs': evalLogs,
        },
      );
    } catch (e, stack) {
      stderr.writeln(
          '[mcp:get_navigation_stack] Error retrieving navigation: $e\n$stack');
      return CallToolResult(
        content: [TextContent(text: 'Failed to retrieve navigation stack: $e')],
        isError: true,
      );
    }
  }
}

/// Represents a flattened, simplified widget node from the widget tree.
final class _FlatWidget {
  /// Creates a new [_FlatWidget] data container.
  const _FlatWidget({
    required this.type,
    required this.depth,
    required this.isProjectWidget,
    required this.childCount,
    this.id,
    this.sourceFile,
    this.sourceLine,
    this.properties,
  });

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

const String _navigationStackScript = r'''
jsonEncode((() {
  final blacklist = {
    "Builder", "StatefulBuilder", "StatelessBuilder", "Directionality",
    "MediaQuery", "Theme", "AnimatedTheme", "IconTheme", "DefaultTextStyle",
    "Localizations", "Semantics", "Focus", "FocusScope", "Actions", "Shortcuts",
    "Navigator", "Overlay", "AbsorbPointer", "IgnorePointer", "GestureDetector",
    "RawGestureDetector", "Listener", "MouseRegion", "TickerMode", "AnimatedSize",
    "CustomPaint", "RepaintBoundary", "CompositedTransformTarget", "CompositedTransformFollower",
    "Padding", "Align", "Center", "SizedBox", "ConstrainedBox", "Container",
    "AnimatedBuilder", "SlideTransition", "FadeTransition", "ScaleTransition",
    "RotationTransition", "SizeTransition", "DecoratedBox", "ColoredBox",
    "DefaultSelectionStyle", "SelectionArea", "OverlayPortal", "CheckedModeBanner",
    "Title", "DefaultTextEditingActions", "TapRegion", "ShortcutRegistrar",
    "NotificationListener", "KeyedSubtree", "BlockSemantics", "ExcludeSemantics",
    "ModalBarrier", "SemanticsDebugger", "RawImage", "Image", "Icon",
    "InheritedTheme", "DefaultColor", "RichText", "RawKeyboardListener",
    "PrimaryScrollController", "ScrollConfiguration", "Scrollable", "Viewport",
    "ShrinkWrappingViewport", "SliverPadding", "SliverList", "SliverGrid",
    "ListWheelViewport", "IgnoreBaseline", "Visibility", "AnimatedDefaultTextStyle",
    "AnimatedPhysicalModel", "PhysicalModel", "MetaSheets", "BlocProvider",
    "BlocBuilder", "BlocListener", "MultiBlocProvider", "Provider", "Consumer",
    "ListenableProvider", "ChangeNotifierProvider", "PageStorage", "Offstage",
    "AutomaticKeepAlive", "KeepAlive", "FocusMarker", "ShortcutsMarker",
    "ActionsMarker", "PopScope", "FocusTraversalGroup", "InheritedGoRouter",
    "InheritedProvider", "ListenableProvider", "DeferredInheritedProvider"
  };
  String? currentUrl;
  String? staticRouteTree;
  final delegatesList = <String>[];
  final logsList = <String>[];

  void inspectRouter(dynamic el) {
    if (el == null) return;
    try {
      dynamic delegate;
      dynamic parser;
      dynamic provider;

      final wt = el.widget.runtimeType.toString();
      if (wt.startsWith("Router<") || wt == "Router") {
        try {
          final dynamic router = el.widget;
          delegate = router.routerDelegate;
          parser = router.routeInformationParser;
          provider = router.routeInformationProvider;
        } catch (_) {}
      }

      if (delegate == null) {
        try { delegate = (el.widget as dynamic).routerDelegate; } catch (_) {}
      }
      if (parser == null) {
        try { parser = (el.widget as dynamic).routeInformationParser; } catch (_) {}
      }
      if (provider == null) {
        try { provider = (el.widget as dynamic).routeInformationProvider; } catch (_) {}
      }

      if (provider != null) {
        try {
          final dynamic routeInfo = provider.value;
          if (routeInfo != null) {
            final String? loc = routeInfo.uri?.toString() ?? routeInfo.location;
            if (loc != null && loc.isNotEmpty) {
              logsList.add("Found location via RouteInformationProvider: $loc");
              if (currentUrl == null || loc.length > currentUrl!.length) {
                currentUrl = loc;
              }
            }
          }
        } catch (_) {}
      }

      if (delegate != null) {
        final delType = delegate.runtimeType.toString();
        delegatesList.add(delType);

        try {
          final dynamic config = delegate.currentConfiguration;
          if (config != null) {
            String? loc;
            if (parser != null) {
              try {
                final dynamic routeInfo = parser.restoreRouteInformation(config);
                loc = routeInfo?.uri?.toString() ?? routeInfo?.location;
              } catch (_) {}
            }
            if (loc == null) {
              try { loc = config.uri?.toString(); } catch (_) {}
            }
            if (loc == null) {
              try { loc = config.location as String?; } catch (_) {}
            }
            if (loc != null && loc.isNotEmpty) {
              logsList.add("Found location via generic Router config: $loc");
              if (currentUrl == null || loc.length > currentUrl!.length) {
                currentUrl = loc;
              }
            }
          }
        } catch (e) {
          logsList.add("Generic Router resolve log: $e");
        }

        try {
          final dynamic configuration = (delegate as dynamic).configuration;
          if (configuration != null) {
            staticRouteTree ??= configuration.debugKnownRoutes() as String?;
          }
        } catch (_) {}
      }
    } catch (_) {}
    el.visitChildren(inspectRouter);
  }

  String? getScreenName(dynamic route) {
    if (route == null) return null;
    final genericWrappers = {"Builder", "StatefulBuilder", "StatelessBuilder", "anonymous"};
    String? reflectedName;
    try {
      final dynamic builder = (route as dynamic).builder;
      if (builder != null) {
        final str = builder.runtimeType.toString();
        if (str.contains('=>')) reflectedName = str.split('=>').last.trim();
      }
    } catch (_) {}
    if (reflectedName == null) {
      try {
        final dynamic pageBuilder = (route as dynamic).pageBuilder;
        if (pageBuilder != null) {
          final str = pageBuilder.runtimeType.toString();
          if (str.contains('=>')) reflectedName = str.split('=>').last.trim();
        }
      } catch (_) {}
    }
    if (reflectedName == null) {
      try {
        final dynamic child = (route.settings as dynamic).child;
        if (child != null) reflectedName = child.runtimeType.toString();
      } catch (_) {}
    }

    if (reflectedName != null) {
      final cleanReflected = reflectedName.split("<").first;
      final isGeneric = genericWrappers.contains(cleanReflected) ||
          cleanReflected.contains("Provider") ||
          cleanReflected.contains("Consumer") ||
          cleanReflected.contains("Selector");
      if (!isGeneric) {
        return reflectedName;
      }
    }

    try {
      final context = route.subtreeContext;
      if (context != null) {
        String? foundName;
        String? fallbackName;
        void walk(dynamic el, int depth) {
          if (foundName != null || el == null || depth > 40) return;
          try {
            final dynamic widget = el.widget;
            if (inspectorService != null && inspectorService._isValueCreatedByLocalProject(widget)) {
              final wType = widget.runtimeType.toString();
              final baseWType = wType.split("<").first;
              bool isGeneric = genericWrappers.contains(baseWType) ||
                  baseWType.contains("Provider") ||
                  baseWType.contains("Consumer") ||
                  baseWType.contains("Selector") ||
                  baseWType.contains("Bloc") ||
                  baseWType.contains("Builder") ||
                  blacklist.contains(baseWType);
              if (!isGeneric) {
                foundName = wType;
                return;
              }
            }
          } catch (_) {}
          final typeStr = el.widget.runtimeType.toString();
          final baseType = typeStr.split("<").first;
          bool ignore = blacklist.contains(baseType) ||
              baseType.contains("Provider") ||
              baseType.contains("Bloc") ||
              baseType.contains("Consumer") ||
              baseType.contains("Selector") ||
              baseType.contains("GoRouter") ||
              baseType.contains("Scope");
          if (!typeStr.startsWith("_") && !ignore) {
            fallbackName ??= typeStr;
          }
          el.visitChildren((child) => walk(child, depth + 1));
        }
        walk(context, 0);
        if (foundName != null) return foundName;
        if (fallbackName != null) return fallbackName;
      }
    } catch (_) {}

    try {
      final name = route.settings?.name;
      if (name != null && name != '/' && name != 'anonymous') {
        return name;
      }
    } catch (_) {}

    return reflectedName;
  }

  /* Walks up the element tree using element reflection to find the ModalRoute.
     We do this to avoid referencing the 'ModalRoute' class identifier directly,
     which might compile-fail depending on library context/imports. */
  dynamic findParentRoute(dynamic el) {
    dynamic current = el;
    while (current != null) {
      try {
        if (current.runtimeType.toString() == "StatefulElement" &&
            current.state.runtimeType.toString().contains("_ModalScopeState")) {
          return current.state.widget.route;
        }
      } catch (_) {}
      try {
        current = current._parent;
      } catch (_) {
        break;
      }
    }
    return null;
  }

  final navList = <Map<String, dynamic>>[];
  void findNavigators(dynamic el, int? parentNavId) {
    if (el == null) return;
    int? myNavId = parentNavId;
    try {
      if (el.runtimeType.toString() == "StatefulElement" &&
          el.state.runtimeType.toString() == "NavigatorState") {
        final nav = el.state;
        final id = nav.hashCode;
        int? parentRouteHash;
        try {
          final pr = findParentRoute(el);
          if (pr != null) parentRouteHash = pr.hashCode;
        } catch (_) {}
        final routes = <Map<String, dynamic>>[];
        try {
          final present = <dynamic>[];
          for (final e in nav._history) {
            try {
              if (e.runtimeType.toString().contains("RouteEntry")) {
                bool presentFlag = true;
                try { presentFlag = e.isPresent; } catch (_) {}
                if (presentFlag && e.route != null) {
                  present.add(e.route);
                }
              } else {
                present.add(e);
              }
            } catch (_) {}
          }
          final total = present.length;
          final cap = 20;
          final kept = total <= cap ? present : [...present.take(10), ...present.skip(total - 10)];
          bool trimmed = total > cap;
          for (final route in kept) {
            String? name;
            try {
              name = route.settings.name;
            } catch (_) {}
            if (name == null) {
              try {
                final keyVal = (route.settings as dynamic).key?.value;
                if (keyVal is String && keyVal.isNotEmpty) name = keyVal;
              } catch (_) {}
            }
            if (name == null) name = "anonymous";

            bool isCurrent = false;
            bool isFirst = false;
            try { isCurrent = route.isCurrent; } catch (_) {}
            try { isFirst = route.isFirst; } catch (_) {}

            String? screenName = getScreenName(route);
            String routeType = "Route";
            try {
              routeType = route.runtimeType.toString();
            } catch (_) {}
            String settingsType = "RouteSettings";
            try {
              settingsType = route.settings.runtimeType.toString();
            } catch (_) {}
            int routeHash = route.hashCode;

            routes.add({
              "name": name,
              "screenName": screenName,
              "type": routeType,
              "settingsType": settingsType,
              "hash": routeHash,
              "isCurrent": isCurrent,
              "isFirst": isFirst
            });
          }
          if (trimmed) {
            routes.insert(10, {
              "name": "...(${total - 20} routes omitted)...",
              "screenName": null,
              "type": "",
              "settingsType": "",
              "hash": 0,
              "isCurrent": false,
              "isFirst": false
            });
          }
        } catch (_) {}
        navList.add({
          "id": id,
          "parentId": parentNavId,
          "parentRouteHash": parentRouteHash,
          "total": routes.length,
          "routes": routes
        });
        myNavId = id;
      }
    } catch (_) {}
    el.visitChildren((child) => findNavigators(child, myNavId));
  }

  try {
    final root = WidgetsBinding.instance.rootElement;
    if (root != null) {
      inspectRouter(root);
      findNavigators(root, null);
    }
  } catch (e) {
    return {"error": e.toString()};
  }
  return {
    "currentUrl": currentUrl,
    "staticRouteTree": staticRouteTree,
    "navigators": navList,
    "delegates": delegatesList,
    "logs": logsList
  };
})())
''';
