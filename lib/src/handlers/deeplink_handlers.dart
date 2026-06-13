part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for validating App Links and Universal Links configurations.
extension DeeplinkHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleValidateDeepLinks(CallToolRequest req) async {
    final root = _workspaceRoot;
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

    final platform = req.arguments!['platform'] as String;
    final buildVariant = req.arguments?['build_variant'] as String?;
    final configuration = req.arguments?['configuration'] as String?;
    final target = req.arguments?['target'] as String? ?? 'Runner';

    stderr.writeln('[mcp:deeplinks] Validating deep links, platform=$platform');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    final executable = flutterRoot != null
        ? p.join(
            flutterRoot, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter')
        : (Platform.isWindows ? 'flutter.bat' : 'flutter');

    final List<String> args;
    if (platform == 'android') {
      if (buildVariant != null && buildVariant.isNotEmpty) {
        args = [
          'analyze',
          '--android',
          '--output-app-link-settings',
          '--build-variant=$buildVariant',
          root,
        ];
      } else {
        args = [
          'analyze',
          '--android',
          '--list-build-variants',
          root,
        ];
      }
    } else {
      if (configuration != null && configuration.isNotEmpty) {
        args = [
          'analyze',
          '--ios',
          '--output-universal-link-settings',
          '--configuration=$configuration',
          '--target=$target',
          root,
        ];
      } else {
        args = [
          'analyze',
          '--ios',
          '--list-build-options',
          root,
        ];
      }
    }

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
    md.writeln('- Platform: $platform');
    md.writeln('- Exit Code: ${result.exitCode}');
    md.writeln('\nCONSOLE OUTPUT');
    md.writeln(output);

    return _serializeDualFormat(
      title: 'Deep Link Analysis Report',
      markdownBody: md.toString(),
      structuredData: {
        'platform': platform,
        'arguments': args,
        'exit_code': result.exitCode,
        'stdout': output,
        'stderr': result.stderr.toString(),
      },
      format: req.arguments?['format'] as String?,
    );
  }
}
