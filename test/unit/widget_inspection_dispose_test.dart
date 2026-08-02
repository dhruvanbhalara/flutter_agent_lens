import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/memory_debugging_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/mixins/widget_inspection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../helpers/test_mocks.dart';

base class WidgetInspectionSupportMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, WidgetInspectionSupport {
  WidgetInspectionSupportMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        ) {
    registerWidgetTools();
  }

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

base class MemoryDebuggingSupportMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, MemoryDebuggingSupport {
  MemoryDebuggingSupportMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        ) {
    registerMemoryTools();
  }

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

void main() {
  late StreamChannelController<String> controller;
  late FakeVmService fakeVmService;

  setUp(() {
    controller = StreamChannelController<String>();
    fakeVmService = FakeVmService();
  });

  group('WidgetInspectionSupport Cleanup Tests', () {
    test('get_widget_tree disposes inspector object group after completion',
        () async {
      final mock = WidgetInspectionSupportMock(controller.local);
      mock.vmService = fakeVmService;
      mock.isolateId = 'isolate_1';

      fakeVmService.serviceExtensionResponses[
          'ext.flutter.inspector.getRootWidgetSummaryTree'] = {
        'result': {
          'description': 'RootWidget',
          'hasChildren': false,
        }
      };

      fakeVmService
          .serviceExtensionResponses['ext.flutter.inspector.disposeGroup'] = {
        'result': 'success'
      };

      final req = CallToolRequest(
        name: 'widget',
        arguments: {'action': 'get_tree'},
      );

      final result = await mock.callTool(req);
      expect(result.isError, isNot(isTrue));
      expect(fakeVmService.lastExtensionCalled,
          equals('ext.flutter.inspector.disposeGroup'));
      expect(fakeVmService.lastArgs,
          containsPair('objectGroup', startsWith('mcp_inspector_')));
    });

    test('get_widget_tree disposes object group even when root node is null',
        () async {
      final mock = WidgetInspectionSupportMock(controller.local);
      mock.vmService = fakeVmService;
      mock.isolateId = 'isolate_1';

      fakeVmService.serviceExtensionResponses[
          'ext.flutter.inspector.getRootWidgetSummaryTree'] = {'result': null};

      fakeVmService
          .serviceExtensionResponses['ext.flutter.inspector.disposeGroup'] = {
        'result': 'success'
      };

      final req = CallToolRequest(
        name: 'widget',
        arguments: {'action': 'get_tree'},
      );

      final result = await mock.callTool(req);
      expect(result.isError, isTrue);
      expect(fakeVmService.lastExtensionCalled,
          equals('ext.flutter.inspector.disposeGroup'));
    });

    test('inspect_widget disposes object group after layout inspection',
        () async {
      final mock = WidgetInspectionSupportMock(controller.local);
      mock.vmService = fakeVmService;
      mock.isolateId = 'isolate_1';

      fakeVmService.serviceExtensionResponses[
          'ext.flutter.inspector.getDetailsSubtree'] = {
        'result': jsonEncode({
          'description': 'ContainerWidget',
          'properties': [
            {'name': 'size', 'description': 'Size(100, 100)'}
          ]
        })
      };

      fakeVmService
          .serviceExtensionResponses['ext.flutter.inspector.disposeGroup'] = {
        'result': 'success'
      };

      final req = CallToolRequest(
        name: 'widget',
        arguments: {'action': 'inspect', 'widgetId': 'w_123'},
      );

      final result = await mock.callTool(req);
      expect(result.isError, isNot(isTrue));
      expect(fakeVmService.lastExtensionCalled,
          equals('ext.flutter.inspector.disposeGroup'));
    });
  });

  group('MemoryDebuggingSupport Capacity Tests', () {
    test('save_snapshot evicts oldest when capacity exceeds limit', () async {
      final mock = MemoryDebuggingSupportMock(controller.local);
      mock.vmService = fakeVmService;
      mock.isolateId = 'isolate_1';

      for (var i = 1; i <= 4; i++) {
        final req = CallToolRequest(
          name: 'memory',
          arguments: {
            'action': 'save',
            'name': 'snap_$i',
            'limit': 3,
          },
        );
        final res = await mock.callTool(req);
        expect(res.isError, isNot(isTrue));
      }

      expect(mock.memorySnapshots.length, equals(3));
      expect(mock.memorySnapshots.containsKey('snap_1'), isFalse);
      expect(mock.memorySnapshots.containsKey('snap_2'), isTrue);
      expect(mock.memorySnapshots.containsKey('snap_3'), isTrue);
      expect(mock.memorySnapshots.containsKey('snap_4'), isTrue);
    });
  });
}
