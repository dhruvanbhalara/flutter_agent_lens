import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/console_logging_support.dart';
import 'package:flutter_agent_lens/src/mixins/diagnose_project_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class IntegratedToolsMock extends MCPServer
    with
        ToolsSupport,
        VmConnectionSupport,
        ConsoleLoggingSupport,
        DiagnoseProjectSupport {
  IntegratedToolsMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForIntegration extends vm_service.VmService {
  final Completer<void> _onDoneCompleter = Completer<void>();

  FakeVmServiceForIntegration()
      : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<void> get onDone => _onDoneCompleter.future;

  @override
  Future<vm_service.Isolate> getIsolate(String isolateId) async {
    return vm_service.Isolate(
      id: 'isolate_1',
      name: 'main',
      number: '1',
      startTime: 0,
      runnable: true,
      livePorts: 1,
      pauseOnExit: false,
      pauseEvent: vm_service.Event(
        kind: vm_service.EventKind.kPauseStart,
        timestamp: 0,
      ),
      libraries: [],
      breakpoints: [],
    );
  }
}

void main() {
  late StreamChannelController<String> controller;
  late IntegratedToolsMock mock;
  late Directory tempDir;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = IntegratedToolsMock(controller.local);
    mock.vmService = FakeVmServiceForIntegration();
    mock.isolateId = 'isolate_1';
    mock.registerLoggingTools();
    mock.registerDiagnoseProjectTools();
    tempDir = Directory.systemTemp.createTempSync('integration_test_');
    mock.workspaceRoot = tempDir.path;
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('End-to-End Centralized Dynamic Limits & Full Data Bypass', () {
    test(
        'serializeDualFormat enforces 5000 character safety limit on markdown by default',
        () {
      final longMarkdown = 'a' * 10000;
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: const {},
      );

      final result = mock.serializeDualFormat(
        req: req,
        title: 'Safety Test',
        markdownBody: longMarkdown,
        structuredData: {'key': 'val'},
      );

      final text = (result.content.first as TextContent).text;
      expect(text.contains('TRUNCATED'), isTrue);
      expect(text.contains('5000 characters omitted'), isTrue);
    });

    test(
        'serializeDualFormat bypasses markdown limit when full: true is provided',
        () {
      final longMarkdown = 'a' * 10000;
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: const {'full': true},
      );

      final result = mock.serializeDualFormat(
        req: req,
        title: 'Full Test',
        markdownBody: longMarkdown,
        structuredData: {'key': 'val'},
      );

      final text = (result.content.first as TextContent).text;
      expect(text.contains('TRUNCATED'), isFalse);
      expect(text.length, greaterThanOrEqualTo(10000));
    });

    test('serializeDualFormat compacts large structured lists by default', () {
      final list = List.generate(50, (i) => {'index': i, 'value': 'item_$i'});
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: const {},
      );

      final result = mock.serializeDualFormat(
        req: req,
        title: 'List Truncation Test',
        markdownBody: 'Summary',
        structuredData: {'items': list},
      );

      final structured = result.structuredContent! as Map<String, dynamic>;
      final items = structured['items'] as List<dynamic>;
      expect(items.length, equals(20));
    });

    test('serializeDualFormat returns full structured lists when full: true',
        () {
      final list = List.generate(50, (i) => {'index': i, 'value': 'item_$i'});
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: const {'full': true},
      );

      final result = mock.serializeDualFormat(
        req: req,
        title: 'Full List Test',
        markdownBody: 'Summary',
        structuredData: {'items': list},
      );

      final structured = result.structuredContent! as Map<String, dynamic>;
      final items = structured['items'] as List<dynamic>;
      expect(items.length, equals(50));
    });

    test('console_logs fetch respects custom limit and full flag', () async {
      for (var i = 1; i <= 60; i++) {
        mock.addToLogBuffer('[TEST]', 'Log line $i');
      }

      // Default fetch
      final defaultResult = await mock.callTool(
        CallToolRequest(
          name: 'console_logs',
          arguments: const {'action': 'fetch'},
        ),
      );
      final defaultText = (defaultResult.content.first as TextContent).text;
      expect(defaultResult.isError ?? false, isFalse);
      expect(defaultText.contains('Log line 60'), isTrue);

      final defaultData =
          defaultResult.structuredContent! as Map<String, dynamic>;
      expect(defaultData['returned_lines'], equals(50));

      // Custom limit
      final customResult = await mock.callTool(
        CallToolRequest(
          name: 'console_logs',
          arguments: const {'action': 'fetch', 'limit': 10},
        ),
      );
      final customData =
          customResult.structuredContent! as Map<String, dynamic>;
      expect(customData['returned_lines'], equals(10));
    });

    test('diagnose_project bundle_size handles limit and full flag properly',
        () async {
      final sizeFile = File(p.join(tempDir.path, 'code-size-analysis.json'));
      final components = List.generate(
        40,
        (i) => {'name': 'package:lib_$i/module.dart', 'value': 1000 * (40 - i)},
      );
      sizeFile.writeAsStringSync(
          '{"children": ${components.map((c) => '{"n": "${c['name']}", "value": ${c['value']}}').toList()}}');

      // Default limit of 25 capped by list safety limit (20)
      final defaultResult = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: {
            'action': 'bundle_size',
            'analysis_path': sizeFile.path,
          },
        ),
      );
      final defaultData =
          defaultResult.structuredContent! as Map<String, dynamic>;
      final defaultList = defaultData['components'] as List<dynamic>;
      expect(defaultList.length, equals(20));

      // Full true bypasses both query limit and serializer compaction
      final fullResult = await mock.callTool(
        CallToolRequest(
          name: 'diagnose_project',
          arguments: {
            'action': 'bundle_size',
            'analysis_path': sizeFile.path,
            'full': true,
          },
        ),
      );
      final fullData = fullResult.structuredContent! as Map<String, dynamic>;
      final fullList = fullData['components'] as List<dynamic>;
      expect(fullList.length, equals(40));
    });
  });
}
