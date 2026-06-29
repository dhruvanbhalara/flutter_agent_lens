import 'dart:convert';
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

  group('Widget Inspection Tools', () {
    test('get_widget_tree returns parsed widget hierarchy', () async {
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

      // Stub callServiceExtension dynamically
      when(
        () => testServer.mockVmService.callServiceExtension(
          any(),
          isolateId: any(named: 'isolateId'),
          args: any(named: 'args'),
        ),
      ).thenAnswer((invocation) async {
        final method = invocation.positionalArguments[0] as String;
        if (method == 'ext.flutter.inspector.getRootWidgetSummaryTree' ||
            method == 'ext.flutter.inspector.getRootWidgetTree') {
          return Response()
            ..json = {
              'result': jsonEncode({
                'description': 'Root',
                'widgetRuntimeType': 'MyApp',
                'creationLocation': {
                  'file': 'file:///Users/dev/project/lib/main.dart',
                  'line': 10,
                },
                'children': [
                  {
                    'description': 'Container',
                    'widgetRuntimeType': 'Container',
                    'creationLocation': {
                      'file': 'file:///Users/dev/project/lib/main.dart',
                      'line': 15,
                    },
                  }
                ],
              }),
            };
        }
        return Response();
      });

      final res = await testServer.callTool(McpTool.getWidgetTree.name);
      expect(res.isError, isNot(isTrue));
      expect(res.content.first.toString(), contains('MyApp'));
      expect(res.content.first.toString(), contains('Container'));
    });

    test('inspect_widget retrieves layout details', () async {
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

      // Stub callServiceExtension dynamically
      when(
        () => testServer.mockVmService.callServiceExtension(
          any(),
          isolateId: any(named: 'isolateId'),
          args: any(named: 'args'),
        ),
      ).thenAnswer((invocation) async {
        final method = invocation.positionalArguments[0] as String;
        if (method == 'ext.flutter.inspector.getDetailsSubtree') {
          return Response()
            ..json = {
              'result': jsonEncode({
                'description': 'RenderPadding',
                'widgetRuntimeType': 'Container',
                'properties': [
                  {
                    'name': 'constraints',
                    'description': 'BoxConstraints(w=100, h=100)',
                  }
                ],
              }),
            };
        }
        return Response();
      });

      final res = await testServer.callTool(
        McpTool.inspectWidget.name,
        {'widgetId': 'widget-123'},
      );
      expect(res.isError, isNot(isTrue));
      expect(res.content.first.toString(), contains('RenderPadding'));
      expect(res.content.first.toString(), contains('BoxConstraints'));
    });
  });
}
