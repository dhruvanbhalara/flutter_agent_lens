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

  group('Debugger Tools', () {
    test('get_call_stack retrieves stack frames', () async {
      final vm = VM(
        name: 'test-vm',
        version: '3.60',
        operatingSystem: 'macos',
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
        pauseEvent: Event(kind: EventKind.kPauseBreakpoint, timestamp: 0),
        rootLib:
            LibraryRef(id: 'lib-1', name: 'main', uri: 'package:app/main.dart'),
        libraries: [],
      );

      testServer.setConnectedState(
        isolateId: 'isolate-1',
        vm: vm,
        isolate: isolate,
      );

      final mockStack = Stack(
        frames: [
          Frame(
            index: 0,
            function: FuncRef(
              id: 'func-1',
              name: 'calculateTotal',
              owner: LibraryRef(
                id: 'lib-1',
                name: 'main',
                uri: 'package:app/main.dart',
              ),
            ),
            code: CodeRef(id: 'code-1', name: 'calculateTotal'),
            location: SourceLocation(
              script: ScriptRef(id: 'script-1', uri: 'package:app/main.dart'),
              tokenPos: 120,
              line: 45,
              column: 12,
            ),
          ),
        ],
        messages: [],
      );

      // Stub getStack with any arguments
      when(
        () => testServer.mockVmService.getStack(
          any(),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => mockStack);

      final res = await testServer.callTool(McpTool.getCallStack.name);
      expect(res.isError, isNot(isTrue));
      expect(res.content.first.toString(), contains('calculateTotal'));
      expect(
        res.content.first.toString(),
        contains('package:app/main.dart:45'),
      );
    });
  });
}
