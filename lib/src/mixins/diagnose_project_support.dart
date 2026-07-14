import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import '../enums/mcp_tool.dart';
import '../enums/target_platform.dart';
import '../extensions/call_tool_request_x.dart';
import '../utils/process_runner.dart';
import 'vm_connection_support.dart';

/// Support mixin providing tools for analyzing application bundle sizes and validating deep links.
base mixin DiagnoseProjectSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// The process runner helper, allowing test mocks.
  final ProcessRunner processRunner = const ProcessRunner();

  /// Registers the consolidated project diagnostics tool.
  void registerDiagnoseProjectTools() {
    registerTool(
      Tool(
        name: McpTool.diagnoseProject.name,
        description:
            'Run build analysis or validate deep links (details in docs/user_prompt_guide.md).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description: 'Operation (bundle_size, deep_links).',
            ),
            'build_target': StringSchema(
              description:
                  'Target format (apk, appbundle, ios, web; default: apk).',
            ),
            'target_platform': StringSchema(
              description:
                  'Target platform (e.g. android-arm64). Android only.',
            ),
            'analysis_path': StringSchema(
              description: 'Optional path to code-size JSON file.',
            ),
            'platform': StringSchema(
              description:
                  'Platform for deep link checks (android, ios; required for action: deep_links).',
            ),
            'build_variant': StringSchema(
              description: 'Android build variant (debug, release).',
            ),
            'configuration': StringSchema(
              description: 'iOS build configuration (Debug, Release).',
            ),
            'target': StringSchema(
              description: 'iOS target name (default: Runner).',
            ),
            'limit': limitSchema(defaultValue: 25),
          },
          required: ['action'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: true,
        ),
      ),
      _handleDiagnoseProject,
    );
  }

  /// Consolidated project diagnostics handler.
  Future<CallToolResult> _handleDiagnoseProject(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    return switch (action) {
      'bundle_size' => _handleAnalyzeBundleSize(req),
      'deep_links' => _handleValidateDeepLinks(req),
      _ => CallToolResult(
          content: [TextContent(text: 'Unknown action: $action')],
          isError: true,
        ),
    };
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

    File? sizeFile;
    final analysisPath = req.arg<String>('analysis_path');

    if (analysisPath != null && analysisPath.isNotEmpty) {
      if (analysisPath.contains('..') || analysisPath.contains('\x00')) {
        return CallToolResult(
          content: [
            TextContent(
                text:
                    'Invalid analysis path: Path traversal or null byte detected.')
          ],
          isError: true,
        );
      }
      var resolvedPath = analysisPath;
      if (resolvedPath.startsWith('~/')) {
        final home =
            Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
        if (home != null) {
          resolvedPath = p.join(home, resolvedPath.substring(2));
        }
      }
      final customFile = File(resolvedPath);
      if (customFile.existsSync()) {
        sizeFile = customFile;
      } else {
        return CallToolResult(
          content: [
            TextContent(
                text: 'Specified analysis file does not exist: $analysisPath')
          ],
          isError: true,
        );
      }
    } else {
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
            final parentDir = p.basename(entity.parent.path).toLowerCase();
            final isCodeSize = name.contains('code-size-details') ||
                name.contains('code-size-analysis') ||
                name.contains('apk-code-size-analysis') ||
                (parentDir.contains('flutter_size_') &&
                    name.startsWith('snapshot') &&
                    name.endsWith('.json'));
            if (isCodeSize) {
              fallbackFile ??= entity;
              if (matchesTarget(name) || matchesTarget(parentDir)) {
                sizeFile = entity;
                break;
              }
            }
          }
        }
      } catch (e) {
        stderr.writeln(
            '[mcp:bundle_analysis] Error scanning build directory: $e');
      }

      sizeFile ??= fallbackFile;
    }

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
        'A summary of your APK analysis can be found at: ${sizeFile.path}');
    md.writeln(
        'To analyze your app size in Dart DevTools, run the following command:\n'
        '  dart devtools --appSizeBase=${sizeFile.path}');
    md.writeln();
    md.writeln(
        '- Total Calculated Size: ${formatBytes(totalSizeBytes)} ($totalSizeBytes Bytes)');
    md.writeln();
    md.writeln('| Component | Size | Percentage |');
    md.writeln('| :--- | :--- | :--- |');

    final limit = (req.arg<num>('limit'))?.toInt() ?? 25;
    for (final item in leafComponents.take(limit)) {
      final bytes = item['size_bytes'] as int;
      final sizeStr = formatBytes(bytes);
      final pct = totalSizeBytes > 0 ? (bytes / totalSizeBytes) * 100 : 0.0;
      md.writeln(
          '| `${item['name']}` | $sizeStr | ${pct.toStringAsFixed(2)}% |');
    }

    if (leafComponents.length > limit) {
      md.writeln(
          '\n_...and ${leafComponents.length - limit} more components._');
    }

    return serializeDualFormat(
      title: 'Application Bundle Size Details',
      markdownBody: md.toString(),
      structuredData: {
        'file_analyzed': sizeFile.path,
        'total_bytes': totalSizeBytes,
        'components': leafComponents.take(limit).toList(),
      },
    );
  }

  /// Handles the validate_deep_links tool request.
  Future<CallToolResult> _handleValidateDeepLinks(CallToolRequest req) async {
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

    final platformStr = req.requireArg<String>('platform');
    final TargetPlatform platform;
    try {
      platform = TargetPlatform.fromString(platformStr);
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: e.toString())],
        isError: true,
      );
    }

    final buildVariant = req.arg<String>('build_variant');
    final configuration = req.arg<String>('configuration');
    final target = req.arg<String>('target') ?? 'Runner';

    stderr.writeln(
        '[mcp:deeplinks] Validating deep links, platform=${platform.value}');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final executable = flutterRoot != null
        ? p.join(
            flutterRoot, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter')
        : (Platform.isWindows ? 'flutter.bat' : 'flutter');

    final List<String> args = switch (platform) {
      TargetPlatform.android =>
        (buildVariant != null && buildVariant.isNotEmpty)
            ? [
                'analyze',
                '--android',
                '--output-app-link-settings',
                '--build-variant=$buildVariant',
                root,
              ]
            : [
                'analyze',
                '--android',
                '--list-build-variants',
                root,
              ],
      TargetPlatform.ios => (configuration != null && configuration.isNotEmpty)
          ? [
              'analyze',
              '--ios',
              '--output-universal-link-settings',
              '--configuration=$configuration',
              '--target=$target',
              root,
            ]
          : [
              'analyze',
              '--ios',
              '--list-build-options',
              root,
            ],
    };

    stderr.writeln('[mcp:deeplinks] Executing: $executable ${args.join(' ')}');
    final result = await processRunner.run(executable, args);

    if (result.exitCode != 0) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'Flutter deep link analysis failed (Exit Code ${result.exitCode}):\n'
                '${result.stderr}\n'
                'Stdout:\n${result.stdout}',
          )
        ],
        isError: true,
      );
    }

    final output = result.stdout.toString();
    final md = StringBuffer('Deep Link Configuration Analysis\n\n');
    md.writeln('- Platform: ${platform.value}');
    md.writeln('- Exit Code: ${result.exitCode}');
    md.writeln('\nCONSOLE OUTPUT');
    md.writeln(output);

    return serializeDualFormat(
      title: 'Deep Link Analysis Report',
      markdownBody: md.toString(),
      structuredData: {
        'platform': platform.value,
        'arguments': args,
        'exit_code': result.exitCode,
        'stdout': output,
        'stderr': result.stderr.toString(),
      },
    );
  }
}
