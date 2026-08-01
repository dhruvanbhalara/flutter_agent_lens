import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/screenshot_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../helpers/test_mocks.dart';

base class ScreenshotSupportMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, ScreenshotSupport {
  ScreenshotSupportMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        ) {
    registerScreenshotTools();
  }

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

void main() {
  late StreamChannelController<String> controller;
  late FakeVmService fakeVmService;
  late ScreenshotSupportMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    fakeVmService = FakeVmService();
    mock = ScreenshotSupportMock(controller.local);
    mock.vmService = fakeVmService;
    mock.isolateId = 'isolate_1';
    mock.workspaceRoot = Directory.systemTemp.path;
  });

  group('ScreenshotSupport Tool Tests', () {
    test('screenshot take handles service extension call', () async {
      fakeVmService
          .serviceExtensionResponses['ext.flutter.inspector.screenshot'] = {
        'result': {
          'screenshot':
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        }
      };

      final req = CallToolRequest(
        name: 'screenshot',
        arguments: {'action': 'take'},
      );

      final res = await mock.callTool(req);
      expect(res, isNotNull);
    });
  });
}
