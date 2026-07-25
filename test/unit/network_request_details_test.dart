import 'dart:async';
import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/network_capture_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class NetworkDetailsMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, NetworkCaptureSupport {
  NetworkDetailsMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForRequestDetails extends vm_service.VmService {
  final Map<String, dynamic> requestDetailsResponse;
  final bool supportExtension;

  FakeVmServiceForRequestDetails(
    this.requestDetailsResponse, {
    this.supportExtension = true,
  }) : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<vm_service.Isolate> getIsolate(String isolateId) async {
    return vm_service.Isolate(
      id: 'isolate_1',
      name: 'main',
      extensionRPCs: supportExtension ? ['ext.dart.io.getHttpProfile'] : [],
    );
  }

  @override
  Future<vm_service.Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    if (method == 'ext.dart.io.getHttpProfileRequest' ||
        method == 'ext.dart.io.getHttpProfile') {
      return vm_service.Response.parse(requestDetailsResponse)!;
    }
    return vm_service.Response.parse({})!;
  }
}

void main() {
  late StreamChannelController<String> controller;
  late NetworkDetailsMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = NetworkDetailsMock(controller.local);
    mock.registerNetworkTools();
    mock.isolateId = 'isolate_1';
  });

  group('get_request_details action tests', () {
    test('returns error when profile history is empty and requestId is omitted',
        () async {
      mock.vmService = FakeVmServiceForRequestDetails({
        'result': {
          'requests': <Map<String, dynamic>>[],
        }
      });

      final result = await mock.callTool(
        CallToolRequest(
          name: 'network',
          arguments: const {'action': 'get_request_details'},
        ),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.first as TextContent).text,
        contains('No HTTP requests recorded in VM profile history'),
      );
    });

    test('auto-selects most recent request when requestId is omitted',
        () async {
      mock.vmService = FakeVmServiceForRequestDetails({
        'result': {
          'requests': [
            {
              'id': '999',
              'method': 'GET',
              'uri': 'https://api.example.com/auto-latest',
              'startTime': 1000000,
              'endTime': 1200000,
              'request': {
                'headers': <String, dynamic>{},
                'cookies': <dynamic>[],
              },
              'response': {
                'statusCode': 200,
                'headers': <String, dynamic>{},
                'cookies': <dynamic>[],
              },
            }
          ]
        }
      });

      final result = await mock.callTool(
        CallToolRequest(
          name: 'network',
          arguments: const {'action': 'get_request_details'},
        ),
      );

      expect(result.isError ?? false, isFalse);
      expect(
        (result.content.first as TextContent).text,
        contains('https://api.example.com/auto-latest'),
      );
    });

    test('returns error when HTTP profile extension is unsupported', () async {
      mock.vmService = FakeVmServiceForRequestDetails(
        {},
        supportExtension: false,
      );

      final result = await mock.callTool(
        CallToolRequest(
          name: 'network',
          arguments: const {
            'action': 'get_request_details',
            'requestId': '101',
          },
        ),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.first as TextContent).text,
        contains('Network profiling via the Dart VM Service is not supported'),
      );
    });

    test('retrieves full request and response details successfully', () async {
      mock.vmService = FakeVmServiceForRequestDetails({
        'result': {
          'id': '101',
          'method': 'POST',
          'uri': 'https://api.example.com/users/create',
          'startTime': 1000000,
          'endTime': 1250000,
          'request': {
            'headers': {
              'content-type': 'application/json',
              'authorization': 'Bearer token123'
            },
            'cookies': ['session=xyz123'],
            'contentLength': 42,
            'body': '{"name":"John Doe","email":"john@example.com"}',
          },
          'response': {
            'statusCode': 201,
            'reasonPhrase': 'Created',
            'headers': {'content-type': 'application/json; charset=utf-8'},
            'cookies': ['logged_in=true'],
            'contentLength': 58,
            'body': '{"id":101,"status":"success","message":"User created"}',
          },
        }
      });

      final result = await mock.callTool(
        CallToolRequest(
          name: 'network',
          arguments: const {
            'action': 'get_request_details',
            'requestId': '101',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;

      expect(text, contains('POST'));
      expect(text, contains('https://api.example.com/users/create'));
      expect(text, contains('201 Created'));
      expect(text, contains('250.0 ms'));
      expect(text, contains('authorization'));
      expect(text, contains('session=xyz123'));
      expect(text, contains('john@example.com'));
      expect(text, contains('User created'));
    });
  });
}
