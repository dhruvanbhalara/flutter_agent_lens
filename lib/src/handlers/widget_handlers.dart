part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for inspecting widget trees and tracking rebuild frequencies.
extension WidgetHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleWidgetRebuildCounts(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final duration = (req.arguments?['duration_seconds'] as num?)?.toInt() ?? 3;
    stderr.writeln(
        '[mcp:widget_rebuild_counts] Starting rebuild tracking, duration=${duration}s');

    try {
      // First, list available service extensions to verify what's supported
      final isolate = await _vmService!.getIsolate(_isolateId!);
      final extensions = isolate.extensionRPCs ?? [];
      stderr.writeln(
          '[mcp:widget_rebuild_counts] Available extensions: ${extensions.where((e) => e.contains('flutter')).join(', ')}');

      // Check if trackRebuildDirtyWidgets is available
      if (!extensions
          .contains('ext.flutter.inspector.trackRebuildDirtyWidgets')) {
        stderr.writeln(
            '[mcp:widget_rebuild_counts] trackRebuildDirtyWidgets NOT available');
        return CallToolResult(
          content: [
            TextContent(
              text: 'Widget rebuild tracking is not available.\n'
                  'This extension requires a debug-mode Flutter app.\n'
                  'Available Flutter extensions: ${extensions.where((e) => e.contains("flutter")).join(", ")}',
            )
          ],
          isError: true,
        );
      }

      // Enable rebuild tracking
      stderr.writeln(
          '[mcp:widget_rebuild_counts] Enabling trackRebuildDirtyWidgets...');
      await _vmService!.callServiceExtension(
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        isolateId: _isolateId,
        args: {'enabled': 'true'},
      );

      // Maps location ID -> widget name
      final idToName = <String, String>{};
      // Maps location ID -> "file:line"
      final idToFile = <String, String>{};

      void parseLocationsMap(dynamic locationsObj) {
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
                final line = (lines is List && i < lines.length)
                    ? lines[i].toString()
                    : '?';
                final name =
                    (names is List && i < names.length && names[i] != null)
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

      void parseNewLocationsMap(dynamic newLocationsObj) {
        if (newLocationsObj is! Map) return;
        newLocationsObj.forEach((key, value) {
          final filePath = key.toString();
          if (value is List) {
            // Triples: [id, line, column, id, line, column, ...]
            for (var i = 0; i + 2 < value.length; i += 3) {
              final id = value[i].toString();
              final line = value[i + 1].toString();
              idToFile.putIfAbsent(id, () => '$filePath:$line');
            }
          }
        });
      }

      // Pre-seed location lookup map from the widgetLocationIdMap extension
      try {
        final locationResponse = await _vmService!.callServiceExtension(
          'ext.flutter.inspector.widgetLocationIdMap',
          isolateId: _isolateId,
        );
        final rawLocationResult = locationResponse.json?['result'];
        if (rawLocationResult is String) {
          final decoded = jsonDecode(rawLocationResult);
          parseLocationsMap(decoded);
        } else if (rawLocationResult is Map) {
          parseLocationsMap(rawLocationResult);
        }
        stderr.writeln(
            '[mcp:widget_rebuild_counts] Seeded ${idToName.length} widget names from location ID map');
      } catch (e) {
        stderr.writeln(
            '[mcp:widget_rebuild_counts] Warning: Failed to query widgetLocationIdMap: $e');
      }

      // Listen for Extension events that carry rebuild data
      final rebuildEvents = <Map<String, dynamic>>[];
      StreamSubscription? extSub;

      try {
        await _vmService!.streamListen(EventStreams.kExtension);
      } catch (_) {
        // Already listening
      }

      extSub = _vmService!.onExtensionEvent.listen((Event event) {
        if (event.extensionKind == 'Flutter.RebuiltWidgets') {
          final data = event.extensionData?.data;
          if (data != null) {
            rebuildEvents.add(Map<String, dynamic>.from(data));
          }
        }
      });

      stderr.writeln(
          '[mcp:widget_rebuild_counts] Collecting rebuild events for ${duration}s...');
      await Future.delayed(Duration(seconds: duration));

      // Stop listening and disable tracking
      await extSub.cancel();
      await _vmService!.callServiceExtension(
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        isolateId: _isolateId,
        args: {'enabled': 'false'},
      );

      stderr.writeln(
          '[mcp:widget_rebuild_counts] Collected ${rebuildEvents.length} rebuild events');

      final widgetCounts = <String, int>{};
      for (final event in rebuildEvents) {
        // Parse locations and newLocations to update lookup maps
        parseLocationsMap(event['locations']);
        parseNewLocationsMap(event['newLocations']);

        // Count rebuilds per location ID.
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

      // Build results.
      final widgets = <Map<String, dynamic>>[];
      widgetCounts.forEach((locId, count) {
        final name = idToName[locId] ?? 'Widget#$locId';
        final rawFile = idToFile[locId] ?? 'unknown';
        final resolvedPath = _pathResolver != null
            ? _pathResolver!.resolveToAbsolutePath(rawFile)
            : rawFile;
        widgets.add({
          'widget': name,
          'count': count,
          'location': resolvedPath,
          'id': locId,
        });
      });

      // Sort by descending count.
      widgets.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

      final mdBuffer = StringBuffer('### Top Rebuilding Widgets\n\n');
      if (widgets.isEmpty) {
        mdBuffer.writeln(
            'No widget rebuilds recorded during the ${duration}s tracking window.');
        mdBuffer.writeln('');
        mdBuffer.writeln('This can happen if:');
        mdBuffer.writeln(
            '- The app UI was idle (no user interaction or animations)');
        mdBuffer.writeln(
            '- The app is in release mode (tracking only works in debug mode)');
        mdBuffer.writeln('');
        mdBuffer
            .writeln('Raw rebuild events received: ${rebuildEvents.length}');
      } else {
        mdBuffer.writeln('| Widget | Rebuild Count | Source Location |');
        mdBuffer.writeln('| :--- | :--- | :--- |');
        for (final w in widgets.take(20)) {
          mdBuffer.writeln(
              '| **${w['widget']}** | ${w['count']} | `${w['location']}` |');
        }
        if (widgets.length > 20) {
          mdBuffer.writeln('\n_...and ${widgets.length - 20} more widgets._');
        }
      }

      stderr.writeln(
          '[mcp:widget_rebuild_counts] Done. ${widgets.length} widgets tracked.');
      return _serializeDualFormat(
        title: '### Widget Rebuild Analysis',
        markdownBody: mdBuffer.toString(),
        structuredData: {
          'duration_seconds': duration,
          'total_recorded_widgets': widgets.length,
          'raw_events_received': rebuildEvents.length,
          'rebuilds': widgets,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:widget_rebuild_counts] ERROR: $e');
      stderr.writeln('[mcp:widget_rebuild_counts] STACKTRACE: $st');
      return CallToolResult(
          content: [TextContent(text: 'Failed to retrieve rebuild counts: $e')],
          isError: true);
    }
  }

  Future<CallToolResult> _handleEvalExpression(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final expression = req.arguments!['expression'] as String;
    final frameIndex = (req.arguments?['frame_index'] as num?)?.toInt();

    if (frameIndex != null) {
      stderr.writeln('[mcp:evaluate_expression] Evaluating in frame $frameIndex: $expression');
    } else {
      stderr.writeln('[mcp:evaluate_expression] Evaluating in library: $expression');
    }

    try {
      final dynamic res;
      if (frameIndex != null) {
        res = await _vmService!.evaluateInFrame(_isolateId!, frameIndex, expression);
      } else {
        final libraryId = await _getEvaluationLibraryId();
        res = await _vmService!.evaluate(_isolateId!, libraryId, expression);
      }

      final valStr = res is InstanceRef ? res.valueAsString : res.toString();
      final kindStr = res is InstanceRef ? res.kind : 'Unknown';
      final classStr = res is InstanceRef ? res.classRef?.name : 'Unknown';
      return CallToolResult(
        content: [
          TextContent(
              text: '### Evaluation Result\n'
                  '- **Kind**: $kindStr\n'
                  '- **Value**: `$valStr`\n'
                  '- **Class**: $classStr')
        ],
      );
    } catch (e, st) {
      stderr.writeln('[mcp:evaluate_expression] ERROR: $e');
      stderr.writeln('[mcp:evaluate_expression] STACKTRACE: $st');
      return CallToolResult(
          content: [TextContent(text: 'Evaluation failed: $e')], isError: true);
    }
  }

  Future<CallToolResult> _handleScrollGesture(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final controller = req.arguments!['scroll_controller_expression'] as String;
    final offset = (req.arguments?['offset'] as num?)?.toDouble() ?? 500.0;
    stderr.writeln(
        '[mcp:scroll_gesture] Controller: $controller, offset: $offset');

    final script = '$controller.animateTo('
        '$offset,'
        'duration: const Duration(milliseconds: 300),'
        'curve: Curves.easeInOut,'
        ')';

    try {
      final libraryId = await _getEvaluationLibraryId();
      final eval = await _vmService!.evaluate(_isolateId!, libraryId, script);
      final evalStr =
          eval is InstanceRef ? eval.valueAsString : eval.toString();
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Scroll gesture driven successfully. Evaluation result: `$evalStr`')
        ],
      );
    } catch (e, st) {
      stderr.writeln('[mcp:scroll_gesture] ERROR: $e');
      stderr.writeln('[mcp:scroll_gesture] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Failed to drive gesture: $e')],
        isError: true,
      );
    }
  }

  Future<CallToolResult> _handleInspectLayoutConstraints(
      CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final widgetId =
        (req.arguments!['widget_id'] ?? req.arguments!['widgetId']) as String;
    stderr.writeln('[mcp:inspect_layout] Inspecting widget: $widgetId');

    try {
      final response = await _vmService!.callServiceExtension(
        'ext.flutter.inspector.getDetailsSubtree',
        isolateId: _isolateId,
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

      final md =
          StringBuffer('### Layout Constraints for Widget: `$widgetId`\n\n');
      md.writeln('- **Widget Type**: `${result['description'] ?? 'Unknown'}`');
      md.writeln('- **Constraints**: `${constraints ?? 'Not found'}`');
      md.writeln('- **Size**: `${size ?? 'Not found'}`');
      md.writeln('\n#### Diagnostic Properties');
      if (properties.isEmpty) {
        md.writeln('No properties found.');
      } else {
        md.writeln('| Property | Value |');
        md.writeln('| :--- | :--- |');
        properties.forEach((k, v) {
          md.writeln('| $k | `$v` |');
        });
      }

      return _serializeDualFormat(
        title: '### Layout Diagnostics Report',
        markdownBody: md.toString(),
        structuredData: {
          'widget_id': widgetId,
          'description': result['description'] ?? 'Unknown',
          'constraints': constraints,
          'size': size,
          'all_properties': properties,
          'raw_node': result,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:inspect_layout] ERROR: $e');
      stderr.writeln('[mcp:inspect_layout] STACKTRACE: $st');
      return CallToolResult(
        content: [
          TextContent(text: 'Failed to retrieve layout constraints: $e')
        ],
        isError: true,
      );
    }
  }

  Future<CallToolResult> _handleToggleWidgetSelection(
      CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final enabled = req.arguments!['enabled'] as bool;
    stderr.writeln('[mcp:toggle_widget_selection] Setting enabled = $enabled');

    try {
      await _vmService!.callServiceExtension(
        'ext.flutter.inspector.show',
        isolateId: _isolateId,
        args: {'enabled': enabled ? 'true' : 'false'},
      );
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'On-device widget selection overlay is now ${enabled ? "enabled" : "disabled"}.')
        ],
      );
    } catch (e, st) {
      stderr.writeln('[mcp:toggle_widget_selection] ERROR: $e');
      stderr.writeln('[mcp:toggle_widget_selection] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Failed to toggle widget selection: $e')],
        isError: true,
      );
    }
  }

  Future<CallToolResult> _handleTogglePackageWidgets(
      CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final enabled = req.arguments!['enabled'] as bool;
    stderr.writeln('[mcp:toggle_package_widgets] Setting enabled = $enabled');

    final root = _workspaceRoot;
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

    try {
      // 1. Get package paths from package_config.json
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

      // Also add the workspace root itself to be safe
      if (!packagePaths.contains(root)) {
        packagePaths.insert(0, root);
      }

      // 2. Find WidgetInspectorService library
      final isolate = await _vmService!.getIsolate(_isolateId!);
      final widgetInspectorLib = isolate.libraries?.firstWhere(
        (lib) => lib.uri == 'package:flutter/src/widgets/widget_inspector.dart',
        orElse: () => throw StateError(
            'WidgetInspectorService library not found in target isolate.'),
      );

      final libId = widgetInspectorLib!.id!;

      // 3. Format paths literal for Dart array: ['path1', 'path2', ...]
      final pathsLiteral = packagePaths
          .map((p) => "'${p.replaceAll("'", "\\'")}'")
          .toList()
          .toString();

      if (enabled) {
        stderr.writeln(
            '[mcp:toggle_package_widgets] Adding ${packagePaths.length} pub root directories');
        await _vmService!.evaluate(
          _isolateId!,
          libId,
          'WidgetInspectorService.instance.addPubRootDirectories($pathsLiteral)',
        );
      } else {
        stderr.writeln(
            '[mcp:toggle_package_widgets] Removing ${packagePaths.length} pub root directories');
        await _vmService!.evaluate(
          _isolateId!,
          libId,
          'WidgetInspectorService.instance.removePubRootDirectories($pathsLiteral)',
        );
      }

      // Read current pub root directories if possible using evaluate
      var currentDirs = 'unknown';
      try {
        final res = await _vmService!.evaluate(
          _isolateId!,
          libId,
          'WidgetInspectorService.instance.pubRootDirectories',
        );
        if (res is InstanceRef) {
          currentDirs = res.valueAsString ?? res.toString();
        } else {
          currentDirs = res.toString();
        }
      } catch (_) {}

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
    } catch (e, st) {
      stderr.writeln('[mcp:toggle_package_widgets] ERROR: $e');
      stderr.writeln('[mcp:toggle_package_widgets] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Failed to configure package widgets: $e')],
        isError: true,
      );
    }
  }

  List<String> _getPackageDirectories(String workspaceRoot) {
    final directories = <String>[];
    try {
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
          // Resolve relative to .dart_tool/ directory
          final absolutePath =
              p.canonicalize(p.join(configDir.path, uri.toFilePath()));
          directories.add(absolutePath);
        } else if (uri.scheme == 'file') {
          directories.add(p.canonicalize(uri.toFilePath()));
        }
      }
    } catch (e) {
      stderr.writeln(
          '[mcp:package_resolver] Error parsing package_config.json: $e');
    }
    return directories;
  }

  Future<CallToolResult> _handleToggleDebugFlag(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final flagName = req.arguments!['flag_name'] as String;
    final value = req.arguments!['value'] as String;
    stderr.writeln(
        '[mcp:toggle_debug_flag] Setting flag_name=$flagName to value=$value');

    try {
      final extensionName = 'ext.flutter.$flagName';
      final Map<String, dynamic> args;
      if (flagName == 'timeDilation') {
        final doubleVal = double.tryParse(value) ?? 1.0;
        args = {'timeDilation': doubleVal.toString()};
      } else {
        final boolVal = value == 'true';
        args = {'enabled': boolVal ? 'true' : 'false'};
      }

      await _vmService!.callServiceExtension(
        extensionName,
        isolateId: _isolateId,
        args: args,
      );

      return CallToolResult(
        content: [
          TextContent(
              text: 'Successfully set debug flag `$flagName` to `$value`.')
        ],
      );
    } catch (e, st) {
      stderr.writeln('[mcp:toggle_debug_flag] ERROR: $e');
      stderr.writeln('[mcp:toggle_debug_flag] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Failed to configure debug flag: $e')],
        isError: true,
      );
    }
  }

  Future<CallToolResult> _handleGetWidgetTree(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final maxDepth = (req.arguments?['maxDepth'] as num?)?.toInt() ?? 15;
    final projectOnly = (req.arguments?['projectOnly'] as bool?) ?? false;

    try {
      final objectGroup = 'mcp_inspector_${DateTime.now().millisecondsSinceEpoch}';

      dynamic rootNode;
      try {
        final response = await _vmService!.callServiceExtension(
          'ext.flutter.inspector.getRootWidgetSummaryTree',
          isolateId: _isolateId,
          args: {'objectGroup': objectGroup},
        );
        rootNode = _parseExtensionResult(response);
      } catch (e) {
        final response = await _vmService!.callServiceExtension(
          'ext.flutter.inspector.getRootWidgetTree',
          isolateId: _isolateId,
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
          content: [TextContent(text: 'Unexpected response format for root widget node.')],
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

      return _serializeDualFormat(
        title: '### Widget Tree Summary',
        markdownBody: 'Widget Tree ($totalWidgets widgets, $projectWidgets from project, depth: $maxDepthReached)\n\n$text',
        structuredData: {
          'total_widgets': totalWidgets,
          'project_widgets': projectWidgets,
          'max_depth_reached': maxDepthReached,
          'widgets': flattened.map((w) => w.toMap()).toList(),
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:get_widget_tree] ERROR: $e');
      stderr.writeln('[mcp:get_widget_tree] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Failed to get widget tree: $e')],
        isError: true,
      );
    }
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
          final response = await _vmService!.callServiceExtension(
            'ext.flutter.inspector.getChildrenSummaryTree',
            isolateId: _isolateId,
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
        } catch (_) {
          // Ignore child fetch failures
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
            childMap,
            objectGroup,
            depth + 1,
            maxDepth,
          );
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
            _flattenWidgetTree(Map<String, dynamic>.from(child), depth, maxDepth, projectOnly),
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

    final widgetName = creationName ?? widgetRuntimeType ?? description ?? typeStr ?? 'Unknown';

    String? sourceFile;
    int? sourceLine;

    if (isProjectWidget && creationLocation != null) {
      final fileUri = creationLocation['file'] as String?;
      if (fileUri != null) {
        final cleanFile = fileUri.replaceFirst(RegExp(r'^file://'), '');
        final parts = cleanFile.split('/lib/');
        if (parts.length > 1) {
          sourceFile = parts.last;
        } else {
          sourceFile = cleanFile.split('/').last;
        }
      }
      sourceLine = creationLocation['line'] as int?;
    }

    final rawProperties = node['properties'] as List<dynamic>?;
    List<Map<String, String>>? properties;
    if (rawProperties != null && rawProperties.isNotEmpty) {
      properties = [];
      for (final prop in rawProperties) {
        if (prop is Map) {
          final propName = prop['name']?.toString();
          final propDesc = prop['description']?.toString() ?? prop['value']?.toString();
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
          _flattenWidgetTree(Map<String, dynamic>.from(child), depth + 1, maxDepth, projectOnly),
        );
      }
    }

    return results;
  }

  String _formatTreeAsText(List<_FlatWidget> widgets) {
    final buffer = StringBuffer();
    for (final w in widgets) {
      final indent = '  ' * w.depth;
      final projectMarker = w.isProjectWidget ? ' ★' : '';
      final childInfo = w.childCount > 0 ? ' (${w.childCount} children)' : '';
      final sourceInfo = w.sourceFile != null ? ' [${w.sourceFile}:${w.sourceLine}]' : '';

      buffer.write('$indent${w.type}$projectMarker$childInfo$sourceInfo');

      final props = w.properties;
      if (props != null && props.isNotEmpty) {
        final propsStr = props.map((p) => '${p['name']}: ${p['value']}').join(', ');
        buffer.write(' [$propsStr]');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }
}

class _FlatWidget {
  final String type;
  final int depth;
  final String? id;
  final bool isProjectWidget;
  final int childCount;
  final String? sourceFile;
  final int? sourceLine;
  final List<Map<String, String>>? properties;

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
