import 'dart:async';
import 'package:test/test.dart';
import 'package:dart_mcp/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/mixins/network_capture_support.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class NetworkCaptureMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, NetworkCaptureSupport {
  NetworkCaptureMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForNetwork extends vm_service.VmService {
  final Map<String, dynamic> responseMap;

  FakeVmServiceForNetwork(this.responseMap)
      : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<vm_service.Isolate> getIsolate(String isolateId) async {
    return vm_service.Isolate(
      id: 'isolate_1',
      name: 'main',
      extensionRPCs: ['ext.dart.io.getHttpProfile'],
    );
  }

  @override
  Future<vm_service.Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    return vm_service.Response.parse(responseMap)!;
  }
}

void main() {
  late StreamChannelController<String> controller;
  late NetworkCaptureMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = NetworkCaptureMock(controller.local);
    mock.registerNetworkTools();
    mock.vmService = FakeVmServiceForNetwork({});
    mock.isolateId = 'isolate_1';
  });

  group('NetworkCaptureSupport Tests', () {
    test('start network capture fails when already capturing', () async {
      mock.isCapturingNetwork = true;
      final result = await mock.callTool(
        CallToolRequest(
          name: 'network',
          arguments: const {'action': 'start'},
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Already capturing'));
    });

    test('stop network capture fails when not capturing', () async {
      mock.isCapturingNetwork = false;
      final result = await mock.callTool(
        CallToolRequest(
          name: 'network',
          arguments: const {'action': 'stop'},
        ),
      );
      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text,
          contains('Not capturing'));
    });

    test('get_profile action retrieves HTTP profile history', () async {
      mock.vmService = FakeVmServiceForNetwork({
        'result': {
          'requests': [
            {
              'id': '1',
              'method': 'GET',
              'uri': 'https://api.example.com/data',
              'startTime': 1000000,
              'endTime': 1500000,
              'request': {'contentLength': 100},
              'response': {'statusCode': 200, 'contentLength': 500},
            }
          ]
        }
      });
      mock.isolateId = 'isolate_1';

      final result = await mock.callTool(
        CallToolRequest(
          name: 'network',
          arguments: const {
            'action': 'get_profile',
            'limit': 5,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('https://api.example.com/data'));
      expect(text, contains('500 B'));
    });
  });
}
