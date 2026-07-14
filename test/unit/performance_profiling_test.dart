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
  final Map<String, dynamic> responseMap;
  FakeVmServiceForProfiling(this.responseMap)
      : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<vm_service.Isolate> getIsolate(String isolateId) async {
    return vm_service.Isolate(
      id: 'isolate_1',
      name: 'main',
      extensionRPCs: [],
    );
  }

  @override
  Future<vm_service.Success> setVMTimelineFlags(
      List<String> recordedStreams) async {
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
      expect(text, contains('Janky Frame Events (> 16.6ms): 20'));
      final lines = text.split('\n');
      final jankRows = lines.where((l) => l.contains('20.00')).toList();
      expect(jankRows.length, equals(15));
    });
  });
}
