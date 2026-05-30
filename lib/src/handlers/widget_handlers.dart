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
    stderr.writeln('[mcp:eval_expression] Evaluating: $expression');

    try {
      final libraryId = await _getEvaluationLibraryId();
      final res =
          await _vmService!.evaluate(_isolateId!, libraryId, expression);
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
      stderr.writeln('[mcp:eval_expression] ERROR: $e');
      stderr.writeln('[mcp:eval_expression] STACKTRACE: $st');
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

  Future<CallToolResult> _handleToggleLayoutGuidelines(
      CallToolRequest req) async {
    final enabled = req.arguments!['enabled'] as bool;
    final value = enabled ? 'true' : 'false';
    final request = CallToolRequest(
      name: 'toggle_debug_flag',
      arguments: {'flag_name': 'debugPaint', 'value': value},
    );
    return _handleToggleDebugFlag(request);
  }

  Future<CallToolResult> _handleToggleOversizedImages(
      CallToolRequest req) async {
    final enabled = req.arguments!['enabled'] as bool;
    final value = enabled ? 'true' : 'false';
    final request = CallToolRequest(
      name: 'toggle_debug_flag',
      arguments: {'flag_name': 'invertOversizedImages', 'value': value},
    );
    return _handleToggleDebugFlag(request);
  }

  Future<CallToolResult> _handleToggleRepaintRainbow(
      CallToolRequest req) async {
    final enabled = req.arguments!['enabled'] as bool;
    final value = enabled ? 'true' : 'false';
    final request = CallToolRequest(
      name: 'toggle_debug_flag',
      arguments: {'flag_name': 'repaintRainbow', 'value': value},
    );
    return _handleToggleDebugFlag(request);
  }

  Future<CallToolResult> _handleToggleBaselines(CallToolRequest req) async {
    final enabled = req.arguments!['enabled'] as bool;
    final value = enabled ? 'true' : 'false';
    final request = CallToolRequest(
      name: 'toggle_debug_flag',
      arguments: {'flag_name': 'debugPaintBaselinesEnabled', 'value': value},
    );
    return _handleToggleDebugFlag(request);
  }

  Future<CallToolResult> _handleToggleSlowAnimations(
      CallToolRequest req) async {
    final enabled = req.arguments!['enabled'] as bool;
    final value = enabled ? '5.0' : '1.0';
    final request = CallToolRequest(
      name: 'toggle_debug_flag',
      arguments: {'flag_name': 'timeDilation', 'value': value},
    );
    return _handleToggleDebugFlag(request);
  }
}
