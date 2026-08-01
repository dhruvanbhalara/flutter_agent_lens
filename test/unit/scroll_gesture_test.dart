import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/scroll_gesture_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../helpers/test_mocks.dart';

base class ScrollGestureSupportMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, ScrollGestureSupport {
  ScrollGestureSupportMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        ) {
    registerScrollGestureTools();
  }

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

void main() {
  late StreamChannelController<String> controller;
  late FakeVmService fakeVmService;
  late ScrollGestureSupportMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    fakeVmService = FakeVmService();
    mock = ScrollGestureSupportMock(controller.local);
    mock.vmService = fakeVmService;
    mock.isolateId = 'isolate_1';
  });

  group('ScrollGestureSupport Tool Tests', () {
    test('scroll_gesture dispatches scroll evaluation script', () async {
      final req = CallToolRequest(
        name: 'trigger_scroll_gesture',
        arguments: {
          'scroll_controller_expression': 'PrimaryScrollController.of(context)',
          'offset': 300.0,
        },
      );

      final res = await mock.callTool(req);
      expect(res.isError, isNot(isTrue));
      final text = (res.content.first as TextContent).text;
      expect(text, contains('Scroll gesture driven successfully'));
    });
  });
}
