import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/interfaces/vm_service_client.dart';
import 'package:flutter_agent_lens/src/strategies/tool_action_strategy.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

class MockToolActionStrategy implements ToolActionStrategy {
  @override
  final String actionName;

  final CallToolResult result;

  MockToolActionStrategy(this.actionName, this.result);

  @override
  Future<CallToolResult> execute(
    CallToolRequest request,
    IVmServiceClient client,
  ) async {
    return result;
  }
}

class FakeVmServiceClient implements IVmServiceClient {
  @override
  String? isolateId = 'isolate_1';

  @override
  String? vmServiceUri = 'ws://127.0.0.1:8181/auth/ws';

  @override
  String? workspaceRoot = '/mock/root';

  @override
  VmService? vmService;

  @override
  Future<bool> refreshIsolateId() async => true;

  @override
  Future<String> getEvaluationLibraryId() async => 'lib_1';

  @override
  void cleanupStreams() {}
}

void main() {
  group('ToolActionRegistry Strategy Pattern Tests', () {
    test('dispatches to registered strategy matching action name', () async {
      final strategyA = MockToolActionStrategy(
        'save',
        CallToolResult(content: [TextContent(text: 'Saved snapshot')]),
      );
      final strategyB = MockToolActionStrategy(
        'compare',
        CallToolResult(content: [TextContent(text: 'Compared snapshots')]),
      );

      final registry = ToolActionRegistry([strategyA, strategyB]);
      final fakeClient = FakeVmServiceClient();

      final reqA = CallToolRequest(
        name: 'memory',
        arguments: {'action': 'save'},
      );

      final resA = await registry.dispatch('save', reqA, fakeClient);
      expect(resA.isError, isNot(isTrue));
      expect(
          (resA.content.first as TextContent).text, equals('Saved snapshot'));

      final reqB = CallToolRequest(
        name: 'memory',
        arguments: {'action': 'compare'},
      );

      final resB = await registry.dispatch('compare', reqB, fakeClient);
      expect(resB.isError, isNot(isTrue));
      expect((resB.content.first as TextContent).text,
          equals('Compared snapshots'));
    });

    test('returns error result for unregistered action name', () async {
      final registry = ToolActionRegistry();
      final fakeClient = FakeVmServiceClient();

      final req = CallToolRequest(
        name: 'memory',
        arguments: {'action': 'unknown_action'},
      );

      final res = await registry.dispatch('unknown_action', req, fakeClient);
      expect(res.isError, isTrue);
      expect((res.content.first as TextContent).text,
          contains('Unknown action: unknown_action'));
    });
  });
}
