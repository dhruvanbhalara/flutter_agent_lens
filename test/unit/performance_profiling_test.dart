import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/performance_profiling_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class PerformanceProfilingMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, PerformanceProfilingSupport {
  PerformanceProfilingMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForProfiling extends vm_service.VmService {
  final Completer<void> _onDoneCompleter = Completer<void>();
  final Map<String, dynamic> responseMap;
  bool setFlagsFailedWithRpcError = false;

  FakeVmServiceForProfiling(this.responseMap)
      : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<void> get onDone => _onDoneCompleter.future;

  void triggerDisconnect() {
    if (!_onDoneCompleter.isCompleted) {
      _onDoneCompleter.complete();
    }
  }

  @override
  Future<vm_service.Isolate> getIsolate(String isolateId) async {
    return vm_service.Isolate(
      id: 'isolate_1',
      name: 'main',
      extensionRPCs: ['ext.flutter.restart'],
    );
  }

  @override
  Future<vm_service.VM> getVM() async {
    return vm_service.VM(
      isolates: [
        vm_service.IsolateRef(id: 'isolate_2', name: 'main'),
      ],
    );
  }

  @override
  Future<vm_service.Success> setVMTimelineFlags(
      List<String> recordedStreams) async {
    if (setFlagsFailedWithRpcError) {
      throw vm_service.RPCError('setVMTimelineFlags', 100, 'RPC error');
    }
    return vm_service.Success();
  }

  @override
  Future<vm_service.Success> clearVMTimeline() async {
    return vm_service.Success();
  }

  @override
  Future<vm_service.Timeline> getVMTimeline(
      {int? timeOriginMicros, int? timeExtentMicros}) async {
    return vm_service.Timeline.parse(responseMap)!;
  }

  @override
  Future<vm_service.Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    return vm_service.Response.parse({'type': 'Success'})!;
  }
}

void main() {
  late StreamChannelController<String> controller;
  late PerformanceProfilingMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = PerformanceProfilingMock(controller.local);
    mock.registerPerformanceTools();
    mock.vmService = FakeVmServiceForProfiling({});
    mock.isolateId = 'isolate_1';
  });

  group('PerformanceProfilingSupport Tests', () {
    test('diagnose_jank defaults limit to 15 and respects it', () async {
      mock.vmService = FakeVmServiceForProfiling({
        'traceEvents': List.generate(
            20,
            (i) => {
                  'ph': 'B',
                  'name': 'GPURasterizer::Draw',
                  'cat': 'Flutter',
                  'ts': 100000 + i * 20000,
                  'dur': 20000, // 20ms (> 16.6ms frame time)
                }),
      });

      final result = await mock.callTool(
        CallToolRequest(
          name: 'profiling',
          arguments: const {
            'action': 'diagnose_jank',
            'duration_seconds': 0,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('**Janky Frame Events (> 16.6ms):** 20 (100.0%)'));
      final lines = text.split('\n');
      final jankRows = lines.where((l) => l.contains('20.00')).toList();
      expect(jankRows.length, equals(15));
    });

    test('handleHotReload reassembles UI when DTD is unattached', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'hot_reload',
          arguments: const {},
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Hot reload triggered successfully'));
    });

    test('handleHotRestart updates isolate ID upon completion', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: 'hot_restart',
          arguments: const {},
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Hot restart triggered successfully'));
      expect(mock.isolateId, equals('isolate_2'));
    });

    test('cleanupPerformanceProfiling handles RPCError gracefully', () async {
      final fake = FakeVmServiceForProfiling({});
      fake.setFlagsFailedWithRpcError = true;
      mock.vmService = fake;

      await expectLater(
        mock.cleanupPerformanceProfiling(),
        completes,
      );
      expect(mock.isProfiling, isFalse);
    });

    test('diagnose_jank includes warning when VM disconnects mid-sampling',
        () async {
      final fake = FakeVmServiceForProfiling({});
      mock.vmService = fake;

      final future = mock.callTool(
        CallToolRequest(
          name: 'profiling',
          arguments: const {
            'action': 'diagnose_jank',
            'duration_seconds': 5,
          },
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      fake.triggerDisconnect();

      final result = await future;
      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('> [!WARNING]'));
      expect(text, contains('vm_service_disconnected'));
    });
  });
}
