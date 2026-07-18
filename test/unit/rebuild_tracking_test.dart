import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/rebuild_tracking_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class RebuildTrackingMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, RebuildTrackingSupport {
  RebuildTrackingMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForRebuilds extends vm_service.VmService {
  final StreamController<vm_service.Event> _eventController =
      StreamController<vm_service.Event>.broadcast();

  FakeVmServiceForRebuilds() : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Stream<vm_service.Event> get onExtensionEvent => _eventController.stream;

  void emitRebuildEvent(Map<String, dynamic> data) {
    _eventController.add(vm_service.Event(
      kind: 'Extension',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      extensionKind: 'Flutter.RebuiltWidgets',
      extensionData: vm_service.ExtensionData.parse(data),
    ));
  }

  @override
  Future<vm_service.Isolate> getIsolate(String isolateId) async {
    return vm_service.Isolate(
      id: 'isolate_1',
      name: 'main',
      extensionRPCs: [
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        'ext.flutter.inspector.widgetLocationIdMap',
      ],
    );
  }

  @override
  Future<vm_service.Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    if (method == 'ext.flutter.inspector.widgetLocationIdMap') {
      return vm_service.Response.parse({
        'result': {
          'package:my_app/main.dart': {
            'ids': [1, 2, 3],
            'lines': [10, 20, 30],
            'names': ['AWidget', 'BWidget', 'CWidget']
          }
        }
      })!;
    }
    return vm_service.Response.parse({'type': 'Success'})!;
  }
}

void main() {
  late StreamChannelController<String> controller;
  late RebuildTrackingMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = RebuildTrackingMock(controller.local);
    mock.registerRebuildTrackingTools();
    mock.vmService = FakeVmServiceForRebuilds();
    mock.isolateId = 'isolate_1';
  });

  group('RebuildTrackingSupport Tests', () {
    test('get_counts respects topN and limits the printed output list',
        () async {
      Future.delayed(const Duration(milliseconds: 100), () {
        (mock.vmService! as FakeVmServiceForRebuilds).emitRebuildEvent({
          'events': [1, 10, 2, 20, 3, 5]
        });
      });

      final result = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'get_counts',
            'duration_seconds': 1,
            'topN': 2,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('BWidget'));
      expect(text, contains('AWidget'));
      expect(text, isNot(contains('CWidget')));
    });
  });
}
