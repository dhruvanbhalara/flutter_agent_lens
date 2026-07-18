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
