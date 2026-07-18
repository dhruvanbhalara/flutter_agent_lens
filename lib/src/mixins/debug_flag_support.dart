import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/flutter_debug_flag.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';

/// Support mixin providing tools for toggling Flutter debug paint, overlays, and package widget visibility flags.
base mixin DebugFlagSupport on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers all debug flags and overlays tools.
  void registerDebugFlagTools() {
    registerTool(
      Tool(
        name: McpTool.debugFlag.name,
        description: 'Manage Flutter debug flags and settings. '
            'Actions: toggle (set a Flutter debug flag like debugPaintSizeEnabled), '
            'toggle_package_widgets (show/hide package widgets in the widget tree).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description:
                  'The debug flag action: toggle, toggle_package_widgets.',
            ),
            'flag_name': StringSchema(
              description:
                  'The name of the Flutter debug flag to change (required for toggle). Supported flags: debugPaintSizeEnabled, debugPaintBaselinesEnabled, repaintRainbow, invertOversizedImages, timeDilation.',
            ),
            'value': StringSchema(
              description: 'The new value to set (required for toggle).',
            ),
            'enabled': BooleanSchema(
              description:
                  'Whether to show package widgets (required for toggle_package_widgets).',
            ),
          },
          required: ['action'],
        ),
      ),
      _handleDebugFlag,
    );
  }

  /// Delegates debug flag actions to respective handlers.
  Future<CallToolResult> _handleDebugFlag(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    return switch (action) {
      'toggle' => _handleToggleDebugFlag(req),
      'toggle_package_widgets' => _handleTogglePackageWidgets(req),
      _ => CallToolResult(
          content: [TextContent(text: 'Unknown debug flag action: $action')],
          isError: true,
        ),
    };
  }

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

    final packagePaths = await _getPackageDirectories(root);
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
        .map((p) => "'${p.replaceAll("'", r"\'")}'")
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

  Future<List<String>> _getPackageDirectories(String workspaceRoot) async {
    final directories = <String>[];
    final configPath =
        p.join(workspaceRoot, '.dart_tool', 'package_config.json');
    final file = File(configPath);
    // The package configuration is read asynchronously outside the main rendering path.
    // ignore: avoid_slow_async_io
    if (!await file.exists()) {
      stderr.writeln(
          '[mcp:package_resolver] package_config.json not found at $configPath');
      return directories;
    }

    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    final packages = json['packages'] as List<dynamic>?;
    if (packages == null) return directories;

    final configDir = Directory(p.dirname(configPath));

    for (final package in packages) {
      if (package is! Map) continue;
      final rootUriStr = package['rootUri'] as String?;
      if (rootUriStr == null) continue;

      final rootUri = Uri.parse(rootUriStr);
      final absoluteUri =
          rootUri.isAbsolute ? rootUri : configDir.uri.resolveUri(rootUri);
      if (absoluteUri.scheme == 'file') {
        directories.add(p.canonicalize(absoluteUri.toFilePath()));
      }
    }

    return directories;
  }

  Future<CallToolResult> _handleToggleDebugFlag(CallToolRequest req) async {
    final flagName = req.requireArg<String>('flag_name');
    final valStr = req.requireArg<String>('value');
    stderr.writeln('[mcp:toggle_flag] Flag: $flagName, Target value: $valStr');

    final flag = FlutterDebugFlag.fromString(flagName);
    if (flag == null) {
      return CallToolResult(
        content: [TextContent(text: 'Unsupported debug flag: $flagName')],
        isError: true,
      );
    }

    final extensionName = 'ext.flutter.${flag.extensionSuffix}';
    final args = switch (flag) {
      FlutterDebugFlag.timeDilation => {
          'timeDilation': (double.tryParse(valStr) ?? 1.0).toString(),
        },
      _ => {'enabled': valStr == 'true' ? 'true' : 'false'},
    };

    try {
      final response = await vmService!.callServiceExtension(
        extensionName,
        isolateId: isolateId,
        args: args,
      );

      final resultText = response.json?['result']?.toString() ??
          response.json?.toString() ??
          'Success';

      return CallToolResult(
        content: [
          TextContent(
            text: 'Successfully set debug flag `$flagName` to `$valStr`.\n'
                'Extension result: `$resultText`',
          )
        ],
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Failed to set debug flag: $e')],
        isError: true,
      );
    }
  }
}
