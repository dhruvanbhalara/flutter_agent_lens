import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;
import '../enums/mcp_tool.dart';
import 'vm_connection_support.dart';

/// Support mixin providing tools for validating Android App Links and iOS Universal Links.
base mixin DeeplinkValidationSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers the deep link validation tool.
  void registerDeeplinkTools() {
    final formatSchema = StringSchema(
      description: 'Response format: markdown or json (default: markdown).',
    );

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

    final platformStr = req.arguments!['platform'] as String;
    final TargetPlatform platform;
    try {
      platform = TargetPlatform.fromString(platformStr);
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: e.toString())],
        isError: true,
      );
    }

    final buildVariant = req.arguments?['build_variant'] as String?;
    final configuration = req.arguments?['configuration'] as String?;
    final target = req.arguments?['target'] as String? ?? 'Runner';

    stderr.writeln('[mcp:deeplinks] Validating deep links, platform=${platform.value}');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final executable = flutterRoot != null
        ? p.join(
            flutterRoot, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter')
        : (Platform.isWindows ? 'flutter.bat' : 'flutter');

    final List<String> args = switch (platform) {
      TargetPlatform.android => (buildVariant != null && buildVariant.isNotEmpty)
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
    final result = await Process.run(executable, args);

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
      format: req.arguments?['format'] as String?,
    );
  }
}

/// The target mobile operating system platform for deep link validation.
enum TargetPlatform {
  /// Android OS.
  android('android'),

  /// iOS OS.
  ios('ios');

  /// The raw String representation of the platform.
  final String value;

  const TargetPlatform(this.value);

  /// Resolves the enum from a raw string input, case-insensitively.
  /// Throws an [ArgumentError] if the platform is unsupported.
  static TargetPlatform fromString(String val) {
    return TargetPlatform.values.firstWhere(
      (e) => e.value.toLowerCase() == val.toLowerCase(),
      orElse: () => throw ArgumentError('Unsupported platform: $val'),
    );
  }
}
