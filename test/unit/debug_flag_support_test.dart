import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/debug_flag_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class DebugFlagMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, DebugFlagSupport {
  DebugFlagMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForDebugFlags extends vm_service.VmService {
  String? lastExtensionCalled;
  Map<String, dynamic>? lastArgs;

  FakeVmServiceForDebugFlags() : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<vm_service.Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    lastExtensionCalled = method;
    lastArgs = args;
    return vm_service.Response.parse({'result': 'success'})!;
  }
}

void main() {
  late StreamChannelController<String> controller;
  late DebugFlagMock mock;
  late FakeVmServiceForDebugFlags fakeVm;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = DebugFlagMock(controller.local);
    mock.registerDebugFlagTools();
    fakeVm = FakeVmServiceForDebugFlags();
    mock.vmService = fakeVm;
    mock.isolateId = 'isolate_1';
  });

  group('DebugFlagSupport Unit Tests', () {
    test('toggle debugPaintSizeEnabled successfully', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'debug_flag',
          arguments: const {
            'action': 'toggle',
            'flag_name': 'debugPaintSizeEnabled',
            'value': 'true',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(fakeVm.lastExtensionCalled, equals('ext.flutter.debugPaint'));
      expect(fakeVm.lastArgs?['enabled'], equals('true'));
    });

    test('toggle debugPaintBaselinesEnabled successfully', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'debug_flag',
          arguments: const {
            'action': 'toggle',
            'flag_name': 'debugPaintBaselinesEnabled',
            'value': 'false',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(fakeVm.lastExtensionCalled,
          equals('ext.flutter.debugPaintBaselinesEnabled'));
      expect(fakeVm.lastArgs?['enabled'], equals('false'));
    });

    test('toggle repaintRainbow successfully', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'debug_flag',
          arguments: const {
            'action': 'toggle',
            'flag_name': 'repaintRainbow',
            'value': 'true',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(fakeVm.lastExtensionCalled, equals('ext.flutter.repaintRainbow'));
      expect(fakeVm.lastArgs?['enabled'], equals('true'));
    });

    test('toggle invertOversizedImages successfully', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'debug_flag',
          arguments: const {
            'action': 'toggle',
            'flag_name': 'invertOversizedImages',
            'value': 'true',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(fakeVm.lastExtensionCalled,
          equals('ext.flutter.invertOversizedImages'));
      expect(fakeVm.lastArgs?['enabled'], equals('true'));
    });

    test('toggle timeDilation with double value successfully', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'debug_flag',
          arguments: const {
            'action': 'toggle',
            'flag_name': 'timeDilation',
            'value': '5.0',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(fakeVm.lastExtensionCalled, equals('ext.flutter.timeDilation'));
      expect(fakeVm.lastArgs?['timeDilation'], equals('5.0'));
    });

    test('toggle action with unsupported flag name returns validation error',
        () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'debug_flag',
          arguments: const {
            'action': 'toggle',
            'flag_name': 'unsupported_flag',
            'value': 'true',
          },
        ),
      );

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Unsupported debug flag'));
    });

    test(
        'toggle_package_widgets when workspaceRoot is not configured returns error',
        () async {
      mock.workspaceRoot = null;
      final result = await mock.callTool(
        CallToolRequest(
          name: 'debug_flag',
          arguments: const {
            'action': 'toggle_package_widgets',
            'enabled': true,
          },
        ),
      );

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Workspace root is not configured'));
    });

    test('unknown debug flag action returns error', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'debug_flag',
          arguments: const {
            'action': 'unknown_flag_action',
          },
        ),
      );

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Unknown debug flag action'));
    });
  });
}
