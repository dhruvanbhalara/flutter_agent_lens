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

  group('Performance Profiling Tools', () {
    test('diagnose_jank reports frame statistics and detects jank', () async {
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

      // Stub setVMTimelineFlags, clearVMTimeline and getVMTimeline
      when(() => testServer.mockVmService.setVMTimelineFlags(any()))
          .thenAnswer((_) async => Success());
      when(() => testServer.mockVmService.clearVMTimeline())
          .thenAnswer((_) async => Success());

      final event1 = TimelineEvent()
        ..json = {
          'name': 'Animator::BeginFrame',
          'dur': 10000,
          'ts': 1000,
        };
      final event2 = TimelineEvent()
        ..json = {
          'name': 'GPURasterizer::Draw',
          'dur': 20000,
          'ts': 2000,
        };

      when(() => testServer.mockVmService.getVMTimeline()).thenAnswer(
        (_) async =>
            Timeline(traceEvents: [event1, event2], timeOriginMicros: 0),
      );

      // Stub callServiceExtension dynamically
      when(
        () => testServer.mockVmService.callServiceExtension(
          any(),
          isolateId: any(named: 'isolateId'),
          args: any(named: 'args'),
        ),
      ).thenAnswer((invocation) async {
        final method = invocation.positionalArguments[0] as String;
        if (method == 'ext.flutter.getDisplayRefreshRate') {
          return Response()..json = {'fps': 60.0};
        }
        if (method == 'ext.flutter.activeIsolateFrameHistory') {
          return Response()
            ..json = {
              'frames': [
                {
                  'number': 1,
                  'build': 4000,
                  'raster': 3000,
                  'elapsed': 7000,
                },
                {
                  'number': 2,
                  'build': 12000,
                  'raster': 15000,
                  'elapsed': 27000, // Over 16.67ms -> Jank!
                }
              ],
            };
        }
        return Response();
      });

      final res = await testServer.callTool(
        McpTool.diagnoseJank.name,
        {'duration_seconds': 0}, // Wait 0 seconds to run fast
      );
      expect(res.isError, isNot(isTrue));
      expect(
        res.content.first.toString(),
        contains('Total Frame Events Sampled: 2'),
      );
      expect(
        res.content.first.toString(),
        contains('Janky Frame Events (> 16.6ms): 1'),
      );
    });
  });
}
