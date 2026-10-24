import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/mixins/uri_resolution_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class UriResolutionMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, UriResolutionSupport {
  UriResolutionMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForUriResolution extends vm_service.VmService {
  String? lastMethodCalled;
  String? lastIsolateId;
  List<String>? lastUris;
  List<String?>? urisToReturn;
  bool shouldThrow = false;

  FakeVmServiceForUriResolution()
      : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<vm_service.UriList> lookupResolvedPackageUris(
    String isolateId,
    List<String> uris, {
    bool? local,
  }) async {
    if (shouldThrow) {
      throw vm_service.RPCError(
        'lookupResolvedPackageUris',
        100,
        'RPC failure',
      );
    }
    lastMethodCalled = 'lookupResolvedPackageUris';
    lastIsolateId = isolateId;
    lastUris = uris;
    return vm_service.UriList(
      uris: urisToReturn ?? uris.map((u) => 'file:///$u').toList(),
    );
  }

  @override
  Future<vm_service.UriList> lookupPackageUris(
    String isolateId,
    List<String> uris,
  ) async {
    if (shouldThrow) {
      throw vm_service.RPCError(
        'lookupPackageUris',
        100,
        'RPC failure',
      );
    }
    lastMethodCalled = 'lookupPackageUris';
    lastIsolateId = isolateId;
    lastUris = uris;
    return vm_service.UriList(
      uris: urisToReturn ?? uris.map((u) => 'package:$u').toList(),
    );
  }
}

void main() {
  late StreamChannelController<String> controller;
  late UriResolutionMock mock;
  late FakeVmServiceForUriResolution fakeVm;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = UriResolutionMock(controller.local);
    mock.registerUriResolutionTools();
    fakeVm = FakeVmServiceForUriResolution();
    mock.vmService = fakeVm;
    mock.isolateId = 'isolate_1';
  });

  group('UriResolutionSupport Unit Tests', () {
    test('registerUriResolutionTools registers resolve_uri tool with schema',
        () async {
      final toolsResult = await mock.listTools(ListToolsRequest());
      final tool = toolsResult.tools.firstWhere(
        (t) => t.name == McpTool.resolveUri.name,
      );
      expect(tool.name, equals('resolve_uri'));
      expect(tool.inputSchema.properties, contains('uris'));
      expect(tool.inputSchema.properties, contains('direction'));
      expect(tool.inputSchema.required, contains('uris'));
    });

    test('returns notConnected when vmService is null', () async {
      mock.vmService = null;
      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {
            'uris': ['package:my_app/main.dart'],
          },
        ),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.first as TextContent).text,
        contains('Not connected'),
      );
    });

    test('returns notConnected when isolateId is null', () async {
      mock.isolateId = null;
      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {
            'uris': ['package:my_app/main.dart'],
          },
        ),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.first as TextContent).text,
        contains('Not connected'),
      );
    });

    test('validates uris argument when missing', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {},
        ),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.first as TextContent).text,
        anyOf(contains('uris'), contains('Missing')),
      );
    });

    test('validates uris argument when empty', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {'uris': <String>[]},
        ),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.first as TextContent).text,
        contains('uris'),
      );
    });

    test('validates uris argument when contains non-string elements', () async {
      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {
            'uris': [123, true],
          },
        ),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.first as TextContent).text,
        contains('uris'),
      );
    });

    test('resolves uris to_local by default (package -> file path)', () async {
      fakeVm.urisToReturn = [
        'file:///path/to/my_app/lib/main.dart',
        'file:///path/to/my_app/lib/src/foo.dart',
      ];

      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {
            'uris': [
              'package:my_app/main.dart',
              'package:my_app/src/foo.dart',
            ],
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(fakeVm.lastMethodCalled, equals('lookupResolvedPackageUris'));
      expect(fakeVm.lastIsolateId, equals('isolate_1'));
      expect(
        fakeVm.lastUris,
        equals(['package:my_app/main.dart', 'package:my_app/src/foo.dart']),
      );

      final text = (result.content.first as TextContent).text;
      expect(text, contains('package:my_app/main.dart'));
      expect(text, contains('file:///path/to/my_app/lib/main.dart'));
      expect(text, contains('package:my_app/src/foo.dart'));
      expect(text, contains('file:///path/to/my_app/lib/src/foo.dart'));
    });

    test('resolves uris to_package (file path -> package URI)', () async {
      fakeVm.urisToReturn = [
        'package:my_app/main.dart',
      ];

      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {
            'uris': ['/path/to/my_app/lib/main.dart'],
            'direction': 'to_package',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(fakeVm.lastMethodCalled, equals('lookupPackageUris'));
      expect(fakeVm.lastIsolateId, equals('isolate_1'));
      expect(fakeVm.lastUris, equals(['/path/to/my_app/lib/main.dart']));

      final text = (result.content.first as TextContent).text;
      expect(text, contains('/path/to/my_app/lib/main.dart'));
      expect(text, contains('package:my_app/main.dart'));
    });

    test('handles unresolved and null entries gracefully in markdown',
        () async {
      fakeVm.urisToReturn = [
        'file:///path/to/my_app/lib/main.dart',
        null,
      ];

      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {
            'uris': [
              'package:my_app/main.dart',
              'package:unknown/unknown.dart',
            ],
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('file:///path/to/my_app/lib/main.dart'));
      expect(text, contains('unresolved'));
    });

    test('produces valid JSON response when responseFormat is json', () async {
      mock.responseFormat = 'json';
      fakeVm.urisToReturn = [
        'file:///path/to/my_app/lib/main.dart',
        null,
      ];

      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {
            'uris': [
              'package:my_app/main.dart',
              'package:unknown/unknown.dart',
            ],
            'direction': 'to_local',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(result.structuredContent, isNotNull);
      final structured = result.structuredContent!;
      expect(structured['direction'], equals('to_local'));
      expect(
        structured['results'],
        equals({
          'package:my_app/main.dart': 'file:///path/to/my_app/lib/main.dart',
          'package:unknown/unknown.dart': null,
        }),
      );

      final text = (result.content.first as TextContent).text;
      expect(text, contains('```json'));
      final jsonBlock =
          text.replaceAll('```json', '').replaceAll('```', '').trim();
      final decoded = jsonDecode(jsonBlock) as Map<String, dynamic>;
      final resultsMap = decoded['results'] as Map<String, dynamic>;
      expect(decoded['direction'], equals('to_local'));
      expect(
        resultsMap['package:my_app/main.dart'],
        equals('file:///path/to/my_app/lib/main.dart'),
      );
      expect(resultsMap['package:unknown/unknown.dart'], isNull);
    });

    test('safeToolCall handles exceptions via handleToolError', () async {
      fakeVm.shouldThrow = true;

      final result = await mock.callTool(
        CallToolRequest(
          name: McpTool.resolveUri.name,
          arguments: const {
            'uris': ['package:my_app/main.dart'],
          },
        ),
      );

      expect(result.isError, isTrue);
      expect(
        (result.content.first as TextContent).text,
        contains('resolve_uri execution failed:'),
      );
    });
  });
}
