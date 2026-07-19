import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/diagnose_project_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

base class DiagnoseProjectMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, DiagnoseProjectSupport {
  DiagnoseProjectMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

void main() {
  late StreamChannelController<String> controller;
  late DiagnoseProjectMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = DiagnoseProjectMock(controller.local);
    mock.registerDiagnoseProjectTools();
  });

  group('DiagnoseProjectSupport Tests', () {
    test('diagnose_project with unknown action returns error', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {'action': 'unknown_action'},
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Unknown action'));
    });

    test('bundle_size action with path traversal rejects input', () async {
      mock.workspaceRoot = '/some/workspace';
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'bundle_size',
            'analysis_path': '../../etc/passwd',
          },
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Path traversal'));
    });

    test('deep_links action validation failure when workspace root is missing',
        () async {
      mock.workspaceRoot = null;
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'deep_links',
            'platform': 'android',
          },
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Workspace root is not configured'));
    });

    test('deep_links action validation failure when platform is missing',
        () async {
      mock.workspaceRoot = '/some/workspace';
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'deep_links',
          },
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Missing required argument: platform'));
    });

    test(
        'bundle_size action when analysis file does not exist returns user-friendly instructions',
        () async {
      mock.workspaceRoot = '/non_existent_workspace_root_path_abc';
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'bundle_size',
            'build_target': 'apk',
            'analysis_path': 'build/app-size-analysis.json',
          },
        ),
      );

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Specified analysis file does not exist'));
    });

    test('bundle_size action when build directory does not exist returns error',
        () async {
      mock.workspaceRoot = '/non_existent_workspace_root_path_abc';
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'bundle_size',
            'build_target': 'apk',
          },
        ),
      );

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Build directory does not exist'));
    });

    test('deep_links action with invalid platform returns validation error',
        () async {
      mock.workspaceRoot = '/some/workspace';
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'deep_links',
            'platform': 'windows', // Unsupported
          },
        ),
      );

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Unsupported platform'));
    });

    test(
        'bundle_size action with absolute path outside workspace root rejects input',
        () async {
      mock.workspaceRoot = '/some/workspace';
      final tempFile =
          await File(p.join(Directory.systemTemp.path, 'outside_analysis.json'))
              .create();
      try {
        final result = await mock.callTool(
          CallToolRequest(
            name: 'diagnose_project',
            arguments: {
              'action': 'bundle_size',
              'analysis_path': tempFile.path,
            },
          ),
        );

        expect(result.isError, isTrue);
        final text = (result.content.first as TextContent).text;
        expect(text, contains('Access denied'));
      } finally {
        await tempFile.delete();
      }
    });

    test('deep_links action with invalid build_variant rejects input',
        () async {
      mock.workspaceRoot = '/some/workspace';
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'deep_links',
            'platform': 'android',
            'build_variant': '--inject-flag',
          },
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Invalid build_variant value'));
    });

    test('deep_links action with invalid configuration rejects input',
        () async {
      mock.workspaceRoot = '/some/workspace';
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'deep_links',
            'platform': 'ios',
            'configuration': 'Release; inject_cmd',
          },
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Invalid configuration value'));
    });

    test('deep_links action with invalid target rejects input', () async {
      mock.workspaceRoot = '/some/workspace';
      final result = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: const {
            'action': 'deep_links',
            'platform': 'ios',
            'configuration': 'Release',
            'target': '../escaped_path',
          },
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Invalid target value'));
    });
  });
}
