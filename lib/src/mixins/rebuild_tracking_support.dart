import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';

/// Support mixin providing widget rebuild frequency tracking and analysis tools.
base mixin RebuildTrackingSupport
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

  /// Registers rebuild tracking tools.
  void registerRebuildTrackingTools() {
    registerTool(
      Tool(
        name: McpTool.rebuildTracking.name,
        description: 'Track widget rebuild frequencies. '
            'Actions: start (begin tracking), stop (end and get report), '
            'get_counts (one-shot rebuild count snapshot).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description: 'Action to perform: start, stop, get_counts.',
            ),
            'duration_seconds': durationSchema(),
            'topN': IntegerSchema(
              description:
                  'Number of top rebuilding widgets to list (default: 30).',
            ),
            'exclude_flutter_widgets': BooleanSchema(
              description:
                  'Whether to exclude built-in Flutter/SDK widgets (default: true).',
            ),
          },
          required: ['action'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
        ),
      ),
      _handleRebuildTracking,
    );
  }

  /// Cancels all active rebuild tracking stream subscriptions.
  Future<void> cleanupRebuildTracking() async {
    await rebuildSub?.cancel();
    rebuildSub = null;
    isTrackingRebuilds = false;
    rebuildCounts.clear();
    rebuildIdToName.clear();
    rebuildIdToFile.clear();
  }

  Future<List<Map<String, dynamic>>> _resolveAndFilterWidgets({
    required Map<String, int> counts,
    required Map<String, String> idToName,
    required Map<String, String> idToFile,
    required bool excludeBuiltIn,
    required String? projectName,
  }) async {
    final widgets = <Map<String, dynamic>>[];
    final resolver = pathResolver;

    for (final entry in counts.entries) {
      final locId = entry.key;
      final count = entry.value;
      final name = idToName[locId] ?? 'Widget#$locId';
      final rawFile = idToFile[locId] ?? 'unknown';

      // Apply filter on raw file path BEFORE resolution
      if (excludeBuiltIn &&
          isBuiltInWidget(rawFile, projectName: projectName)) {
        continue;
      }

      final resolvedPath = resolver != null
          ? await resolver.resolveToAbsolutePath(rawFile)
          : rawFile;
      widgets.add({
        'widget': name,
        'count': count,
        'location': resolvedPath,
        'id': locId,
      });
    }

    widgets.sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    return widgets;
  }

  Future<CallToolResult> _handleWidgetRebuildCounts(CallToolRequest req) async {
    final duration = (req.arg<num>('duration_seconds'))?.toInt() ?? 3;
    final topN = (req.arg<num>('topN'))?.toInt() ?? 30;
    final excludeBuiltIn = req.arg<bool>('exclude_flutter_widgets') ?? true;
    final projectName = excludeBuiltIn ? await getProjectPackageName() : null;

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
      await Future<void>.delayed(Duration(seconds: duration));
    } finally {
      await extSub.cancel();
      try {
        await vmService!.callServiceExtension(
          'ext.flutter.inspector.trackRebuildDirtyWidgets',
          isolateId: isolateId,
          args: {'enabled': 'false'},
        );
      } on Exception catch (e) {
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

    final widgets = await _resolveAndFilterWidgets(
      counts: widgetCounts,
      idToName: idToName,
      idToFile: idToFile,
      excludeBuiltIn: excludeBuiltIn,
      projectName: projectName,
    );

    final mdBuffer = StringBuffer('Top Rebuilding Widgets\n\n');
    if (excludeBuiltIn) {
      mdBuffer.writeln(
          '_Note: Built-in Flutter/SDK widgets excluded. Pass `exclude_flutter_widgets: false` to include them._\n');
    }
    if (widgets.isEmpty) {
      mdBuffer.writeln(
          'No rebuilds captured. Make sure you interacted with the app while tracking.');
    } else {
      mdBuffer.writeln('| Widget | Count | Location |');
      mdBuffer.writeln('| :--- | :--- | :--- |');
      for (final w in widgets.take(topN)) {
        mdBuffer.writeln(
            '| `${w['widget']}` | `${w['count']}x` | `${w['location']}` |');
      }
    }

    return serializeDualFormat(
      title: 'Widget Rebuilt Counts Analysis',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'total_recorded_widgets': widgetCounts.length,
        'filtered_count': widgets.length,
        'widgets': widgets.take(topN).toList(),
      },
    );
  }

  Future<CallToolResult> _handleStartTrackingRebuilds(
      CallToolRequest req) async {
    if (isTrackingRebuilds) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Already tracking rebuilds. Call the `rebuild_tracking` tool with action: `stop` first.')
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
              'Rebuild tracking started. Interact with the app now, then call the `rebuild_tracking` tool with action: `stop` to see the report.',
        )
      ],
    );
  }

  Future<CallToolResult> _handleStopTrackingRebuilds(
      CallToolRequest req) async {
    if (!isTrackingRebuilds) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Not tracking rebuilds. Call the `rebuild_tracking` tool with action: `start` first.')
        ],
        isError: true,
      );
    }

    final topN = (req.arg<num>('topN'))?.toInt() ?? 30;
    final excludeBuiltIn = req.arg<bool>('exclude_flutter_widgets') ?? true;
    final projectName = excludeBuiltIn ? await getProjectPackageName() : null;

    stderr.writeln(
        '[mcp:widget_rebuild_counts] Stopping rebuild tracking session...');
    isTrackingRebuilds = false;
    await rebuildSub?.cancel();
    rebuildSub = null;

    try {
      await vmService!.callServiceExtension(
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        isolateId: isolateId,
        args: {'enabled': 'false'},
      );
    } on Exception catch (e) {
      stderr.writeln(
          '[mcp:widget_rebuild_counts] Error disabling trackRebuildDirtyWidgets: $e');
    }

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
    } on Exception catch (e) {
      stderr.writeln('[mcp:widget] Error fetching widget location ID map: $e');
    }

    final widgets = await _resolveAndFilterWidgets(
      counts: rebuildCounts,
      idToName: rebuildIdToName,
      idToFile: rebuildIdToFile,
      excludeBuiltIn: excludeBuiltIn,
      projectName: projectName,
    );

    var totalRebuilds = 0;
    for (final count in rebuildCounts.values) {
      totalRebuilds += count;
    }

    final output = [
      'WIDGET REBUILD REPORT',
      '',
      'SUMMARY',
      'Tracked for ${durationSec}s',
      'Total rebuilds: $totalRebuilds',
      'Unique widgets rebuilt: ${rebuildCounts.length}',
    ];

    if (excludeBuiltIn) {
      output.add(
          'Filtered widgets: ${widgets.length} (excluding built-in Flutter/SDK widgets)');
    }
    output.add('');

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
        final severity = switch (count) {
          > 100 => '[HIGH]',
          > 30 => '[MEDIUM]',
          > 10 => '[LOW]',
          _ => '[OK]',
        };
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
      title: 'Widget Rebuild Report',
      markdownBody: output.join('\n'),
      structuredData: {
        'duration_seconds': double.tryParse(durationSec) ?? 0.0,
        'total_recorded_widgets': rebuildCounts.length,
        'filtered_count': widgets.length,
        'total_rebuilds': totalRebuilds,
        'rebuilds': widgets.take(topN).toList(),
      },
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
    } on RPCError catch (e) {
      if (e.code != 103) {
        stderr.writeln('[mcp:widget] Error listening to extension stream: $e');
      }
    } on Exception catch (e) {
      stderr.writeln('[mcp:widget] Error listening to extension stream: $e');
    }
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

  /// Handles the rebuild_tracking composite tool request.
  Future<CallToolResult> _handleRebuildTracking(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    return switch (action) {
      'start' => _handleStartTrackingRebuilds(req),
      'stop' => _handleStopTrackingRebuilds(req),
      'get_counts' => _handleWidgetRebuildCounts(req),
      _ => CallToolResult(
          content: [
            TextContent(text: 'Unknown rebuild tracking action: $action')
          ],
          isError: true,
        ),
    };
  }
}
