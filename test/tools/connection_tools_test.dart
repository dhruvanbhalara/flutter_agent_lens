import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';
import '../helpers/test_server.dart';

void main() {
  late TestServer testServer;

  setUp(() async {
    testServer = TestServer();
    await testServer.initialize();
  });

  tearDown(() async {
    await testServer.shutdown();
  });

  group('Connection Tools', () {
    test('disconnect returns not connected message if offline', () async {
      final res = await testServer.callTool(McpTool.disconnect.name);
      expect(res.content.first.toString(), contains('Not connected'));
    });

    test('get_app_info returns not connected if offline', () async {
      final res = await testServer.callTool(McpTool.getAppInfo.name);
      expect(res.isError, isTrue);
      expect(res.content.first.toString(), contains('Not connected'));
    });

    test('get_app_info returns VM and isolate details when online', () async {
      final vm = VM(
        name: 'test-vm',
        version: '3.60',
        operatingSystem: 'macos',
        hostCPU: 'Apple M1',
        targetCPU: 'arm64',
        architectureBits: 64,
        pid: 1234,
        isolates: [IsolateRef(id: 'isolate-1', name: 'main', number: '1')],
      );

      final isolate = Isolate(
        id: 'isolate-1',
        name: 'main',
        number: '1',
        startTime: 0,
        runnable: true,
        livePorts: 10,
        pauseOnExit: false,
        pauseEvent: Event(kind: EventKind.kResume, timestamp: 0),
        rootLib:
            LibraryRef(id: 'lib-1', name: 'main', uri: 'package:app/main.dart'),
        libraries: [],
      );

      testServer.setConnectedState(
        isolateId: 'isolate-1',
        vm: vm,
        isolate: isolate,
      );

      final res = await testServer.callTool(McpTool.getAppInfo.name);
      expect(res.isError, isNot(isTrue));
      expect(res.content.first.toString(), contains('VM INFORMATION'));
      expect(res.content.first.toString(), contains('Name: test-vm'));
    });
  });
}
