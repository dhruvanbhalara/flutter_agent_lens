import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import 'package:path/path.dart' as p;
import '../enums/mcp_tool.dart';
import '../extensions/call_tool_request_x.dart';
import 'vm_connection_support.dart';

/// Support mixin providing tools for toggling Flutter debug paint, overlays, and package widget visibility flags.
base mixin DebugFlagSupport on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers all debug flags and overlays tools.
  void registerDebugFlagTools() {
    registerTool(
      Tool(
        name: McpTool.togglePackageWidgets.name,
        description: 'Toggle package widgets visibility.',
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
        description: 'Toggle a Flutter debug flag.',
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

    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final packages = json['packages'] as List<dynamic>?;
    if (packages == null) return directories;

    final configDir = Directory(p.dirname(configPath));

    for (final package in packages) {
      if (package is! Map) continue;
      final rootUriStr = package['rootUri'] as String?;
      if (rootUriStr == null) continue;

      final uri = Uri.parse(rootUriStr);
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

  Future<CallToolResult> _handleToggleDebugFlag(CallToolRequest req) async {
    final flagName = req.requireArg<String>('flag_name');
    final valStr = req.requireArg<String>('value');
    stderr.writeln('[mcp:toggle_flag] Flag: $flagName, Target value: $valStr');

    final String extensionName;
    final Map<String, dynamic> args;

    final cleanFlag = flagName.trim();
    if (cleanFlag == 'debugPaint' || cleanFlag == 'debugPaintSizeEnabled') {
      extensionName = 'ext.flutter.debugPaint';
      final boolVal = valStr == 'true';
      args = {'enabled': boolVal ? 'true' : 'false'};
    } else if (cleanFlag == 'debugPaintBaselines' ||
        cleanFlag == 'debugPaintBaselinesEnabled') {
      extensionName = 'ext.flutter.debugPaintBaselinesEnabled';
      final boolVal = valStr == 'true';
      args = {'enabled': boolVal ? 'true' : 'false'};
    } else if (cleanFlag == 'repaintRainbow' ||
        cleanFlag == 'debugRepaintRainbowEnabled') {
      extensionName = 'ext.flutter.repaintRainbow';
      final boolVal = valStr == 'true';
      args = {'enabled': boolVal ? 'true' : 'false'};
    } else if (cleanFlag == 'invertOversizedImages' ||
        cleanFlag == 'debugInvertOversizedImages') {
      extensionName = 'ext.flutter.invertOversizedImages';
      final boolVal = valStr == 'true';
      args = {'enabled': boolVal ? 'true' : 'false'};
    } else if (cleanFlag == 'timeDilation') {
      extensionName = 'ext.flutter.timeDilation';
      final doubleVal = double.tryParse(valStr) ?? 1.0;
      args = {'timeDilation': doubleVal.toString()};
    } else {
      return CallToolResult(
        content: [TextContent(text: 'Unsupported debug flag: $flagName')],
        isError: true,
      );
    }

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
