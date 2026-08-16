import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/network_capture_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
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
  final Completer<void> _onDoneCompleter = Completer<void>();
  final Map<String, dynamic> responseMap;
  final List<Map<String, dynamic>>? responseSequence;
  int _callIndex = 0;

  FakeVmServiceForNetwork(this.responseMap, {this.responseSequence})
      : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<void> get onDone => _onDoneCompleter.future;

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
    if (method == 'ext.dart.io.getHttpProfile') {
      if (responseSequence != null && responseSequence!.isNotEmpty) {
        final currentMap =
            responseSequence![_callIndex % responseSequence!.length];
        _callIndex++;
        return vm_service.Response.parse(currentMap)!;
      }
    }
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
            'action': 'getProfile',
            'limit': 5,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('https://api.example.com/data'));
      expect(text, contains('500 B'));
    });

    test(
        'watch action counts request as completed if endTime is present even when response is null',
        () async {
      mock.vmService = FakeVmServiceForNetwork(
        const <String, dynamic>{},
        responseSequence: <Map<String, dynamic>>[
          <String, dynamic>{
            'result': <String, dynamic>{
              'requests': <dynamic>[],
            }
          },
          <String, dynamic>{
            'result': <String, dynamic>{
              'requests': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'req_1',
                  'method': 'POST',
                  'uri': 'https://api.example.com/submit',
                  'startTime': 1000000,
                  'endTime': 1200000,
                  'request': <String, dynamic>{'contentLength': 50},
                  'response': null,
                }
              ]
            }
          }
        ],
      );
      mock.isolateId = 'isolate_1';

      final result = await mock.callTool(
        CallToolRequest(
          name: 'network',
          arguments: const {
            'action': 'watch',
            'durationSeconds': 1,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('LIVE NETWORK WATCH REPORT'));
      expect(text, contains('Completed: 1'));
    });
  });
}
