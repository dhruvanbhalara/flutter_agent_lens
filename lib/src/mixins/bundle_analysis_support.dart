import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;
import '../enums/mcp_tool.dart';
import '../extensions/call_tool_request_x.dart';
import 'vm_connection_support.dart';

/// Support mixin providing tools for analyzing application bundle sizes.
base mixin BundleAnalysisSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers all application bundle size analysis tools.
  void registerBundleAnalysisTools() {
    registerTool(
      Tool(
        name: McpTool.analyzeBundleSize.name,
        description:
            'Analyze build size details from size mapping files in the build/ directory.',
        inputSchema: ObjectSchema(
          properties: {
            'build_target': StringSchema(
              description:
                  'Target format to inspect (e.g. apk, appbundle, ios, web; default: apk).',
            ),
            'target_platform': StringSchema(
              description:
                  'Specific target platform (e.g. android-arm64, android-arm, android-x64). Only used for Android.',
            ),
            'format': formatSchema,
          },
        ),
      ),
      _handleAnalyzeBundleSize,
    );
  }

  /// Handles the analyze_bundle_size tool request.
  Future<CallToolResult> _handleAnalyzeBundleSize(CallToolRequest req) async {
    final root = workspaceRoot;
    if (root == null || root.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Workspace root is not configured. Run connect first to set it.')
        ],
        isError: true,
      );
    }

    String defaultTarget = 'apk';
    if (vmService != null) {
      try {
        final vm = await vmService!.getVM();
        final os = vm.operatingSystem?.toLowerCase();
        if (os == 'ios') {
          defaultTarget = 'ios';
        } else if (os == 'macos') {
          defaultTarget = 'macos';
        } else if (os == 'windows') {
          defaultTarget = 'windows';
        } else if (os == 'linux') {
          defaultTarget = 'linux';
        }
      } catch (e) {
        stderr.writeln(
            '[mcp:bundle_size] Error auto-detecting target OS from VM: $e');
      }
    }

    final target = req.arg<String>('build_target') ?? defaultTarget;
    final targetPlatform = req.arg<String>('target_platform') ??
        ((target == 'apk' || target == 'appbundle') ? 'android-arm64' : '');

    stderr.writeln(
        '[mcp:bundle_size] Analyzing bundle size, target=$target, platform=$targetPlatform');

    final buildDir = Directory(p.join(root, 'build'));
    if (!buildDir.existsSync()) {
      return CallToolResult(
        content: [
          TextContent(
              text: 'Build directory does not exist at ${buildDir.path}.')
        ],
        isError: true,
      );
    }

    File? sizeFile;
    File? fallbackFile;
    final targetLower = target.toLowerCase();

    bool matchesTarget(String name) {
      if (target == 'apk' || target == 'appbundle') {
        return name.contains('apk') ||
            name.contains('appbundle') ||
            name.contains('android');
      }
      return name.contains(targetLower);
    }

    try {
      final fileEntities = buildDir.listSync(recursive: true);
      for (final entity in fileEntities) {
        if (entity is File) {
          final name = p.basename(entity.path).toLowerCase();
          final isCodeSize = name.contains('code-size-details') ||
              name.contains('code-size-analysis');
          if (isCodeSize) {
            fallbackFile ??= entity;
            if (matchesTarget(name)) {
              sizeFile = entity;
              break;
            }
          }
        }
      }
    } catch (e) {
      stderr
          .writeln('[mcp:bundle_analysis] Error scanning build directory: $e');
    }

    sizeFile ??= fallbackFile;

    if (sizeFile == null || !sizeFile.existsSync()) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'No size analysis file found in the build directory.\n\n'
                'Please run the following command manually to generate the size analysis file, then try again:\n\n'
                '  flutter build $target --analyze-size ${targetPlatform.isNotEmpty ? "--target-platform=$targetPlatform" : ""}',
          )
        ],
        isError: true,
      );
    }

    stderr.writeln(
        '[mcp:bundle_size] Parsing size analysis file: ${sizeFile.path}');
    final dynamic rawJson;
    try {
      rawJson = jsonDecode(await sizeFile.readAsString());
    } catch (e) {
      return CallToolResult(
        content: [
          TextContent(text: 'Failed to parse size analysis JSON file: $e')
        ],
        isError: true,
      );
    }
    if (rawJson is! Map<String, dynamic>) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Invalid size analysis file format: Root is not a JSON object.')
        ],
        isError: true,
      );
    }

    final leafComponents = <Map<String, dynamic>>[];

    void visit(Map<String, dynamic> node, int depth) {
      if (depth > 20) return;
      final name = (node['n'] ?? node['name'])?.toString() ?? 'unknown';
      final value = node['value'] ?? node['size'];

      final children = node['children'];
      if (children is List && children.isNotEmpty) {
        for (final child in children) {
          if (child is Map<String, dynamic>) {
            visit(child, depth + 1);
          }
        }
      } else if (value is num) {
        leafComponents.add({
          'name': name,
          'size_bytes': value.toInt(),
        });
      }
    }

    visit(rawJson, 0);

    // Sort by size descending
    leafComponents.sort(
        (a, b) => (b['size_bytes'] as int).compareTo(a['size_bytes'] as int));

    final totalSizeBytes = leafComponents.fold<int>(
        0, (sum, item) => sum + (item['size_bytes'] as int));

    final md =
        StringBuffer('Code Size Analysis: ${p.basename(sizeFile.path)}\n\n');
    md.writeln(
        '- Total Calculated Size: ${formatBytes(totalSizeBytes)} ($totalSizeBytes Bytes)');
    md.writeln();
    md.writeln('| Component | Size | Percentage |');
    md.writeln('| :--- | :--- | :--- |');

    for (final item in leafComponents.take(25)) {
      final bytes = item['size_bytes'] as int;
      final sizeStr = formatBytes(bytes);
      final pct = totalSizeBytes > 0 ? (bytes / totalSizeBytes) * 100 : 0.0;
      md.writeln(
          '| `${item['name']}` | $sizeStr | ${pct.toStringAsFixed(2)}% |');
    }

    if (leafComponents.length > 25) {
      md.writeln('\n_...and ${leafComponents.length - 25} more components._');
    }

    return serializeDualFormat(
      title: 'Application Bundle Size Details',
      markdownBody: md.toString(),
      structuredData: {
        'file_analyzed': sizeFile.path,
        'total_bytes': totalSizeBytes,
        'components': leafComponents,
      },
      format: req.arg<String>('format'),
    );
  }
}
