import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;
import '../enums/mcp_tool.dart';
import '../enums/target_platform.dart';
import '../extensions/call_tool_request_x.dart';
import 'vm_connection_support.dart';
import '../utils/process_runner.dart';

/// Support mixin providing tools for validating Android App Links and iOS Universal Links.
base mixin DeeplinkValidationSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// The process runner helper, allowing test mocks.
  ProcessRunner processRunner = const ProcessRunner();

  /// Registers the deep link validation tool.
  void registerDeeplinkTools() {
    registerTool(
      Tool(
        name: McpTool.validateDeepLinks.name,
        description: 'Validate deep link configurations on Android or iOS.',
        inputSchema: ObjectSchema(
          properties: {
            'platform': StringSchema(
              description: 'The target platform (android or ios).',
            ),
            'build_variant': StringSchema(
              description:
                  'The build variant for Android (e.g., debug, release).',
            ),
            'configuration': StringSchema(
              description:
                  'The build configuration for iOS (e.g., Debug, Release).',
            ),
            'target': StringSchema(
              description: 'The target name for iOS (default: Runner).',
            ),
            'format': formatSchema,
          },
          required: ['platform'],
        ),
      ),
      _handleValidateDeepLinks,
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
      format: req.arg<String>('format'),
    );
  }
}
