import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/debugger_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../helpers/test_mocks.dart';

base class DebuggerSupportMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, DebuggerSupport {
  DebuggerSupportMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        ) {
    registerDebuggerTools();
  }

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

void main() {
  late StreamChannelController<String> controller;
  late FakeVmService fakeVmService;
  late DebuggerSupportMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    fakeVmService = FakeVmService();
    mock = DebuggerSupportMock(controller.local);
    mock.vmService = fakeVmService;
    mock.isolateId = 'isolate_1';
  });

  group('DebuggerSupport Tool Tests', () {
    test('get_call_stack retrieves stack frames correctly', () async {
      final req = CallToolRequest(
        name: 'get_call_stack',
        arguments: {'limit': 10},
      );

      final res = await mock.callTool(req);
      expect(res.isError, isNot(isTrue));
      final text = (res.content.first as TextContent).text;
      expect(text, contains('myFunction'));
      expect(text, contains('package:my_app/main.dart:42'));
    });

    test('breakpoint add sets breakpoint on isolate', () async {
      final req = CallToolRequest(
        name: 'breakpoint',
        arguments: {
          'action': 'add',
          'file_path': 'package:my_app/main.dart',
          'line': 42,
        },
      );

      final res = await mock.callTool(req);
      expect(res.isError, isNot(isTrue));
      final text = (res.content.first as TextContent).text;
      expect(text, contains('Breakpoint Set Successfully'));
      expect(text, contains('bp_1'));
    });

    test('breakpoint remove deletes breakpoint from isolate', () async {
      final req = CallToolRequest(
        name: 'breakpoint',
        arguments: {
          'action': 'remove',
          'breakpoint_id': 'bp_1',
        },
      );

      final res = await mock.callTool(req);
      expect(res.isError, isNot(isTrue));
      final text = (res.content.first as TextContent).text;
      expect(text, contains('Successfully removed breakpoint'));
    });

    test('evaluate_expression evaluates Dart expression in scope', () async {
      final req = CallToolRequest(
        name: 'evaluate_expression',
        arguments: {
          'expression': '1 + 1',
        },
      );

      final res = await mock.callTool(req);
      expect(res.isError, isNot(isTrue));
      final text = (res.content.first as TextContent).text;
      expect(text, contains('Evaluation Result'));
    });
  });
}
