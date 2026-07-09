import 'package:test/test.dart';
import 'package:dart_mcp/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/mixins/connection_support.dart';
import 'package:flutter_agent_lens/src/mixins/console_logging_support.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';

base class VmConnectionSupportMock extends MCPServer
    with ToolsSupport, VmConnectionSupport {
  VmConnectionSupportMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

void main() {
  late StreamChannelController<String> controller;
  late VmConnectionSupportMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = VmConnectionSupportMock(controller.local);
  });

  group('VmConnectionSupport Utility Tests', () {
    test('isDtdUri checks for DTD vs direct VM connection', () {
      // Direct VM connection uris
      expect(mock.isDtdUri('ws://127.0.0.1:8181/auth_token/ws'), isFalse);
      expect(mock.isDtdUri('http://127.0.0.1:8181/auth_token/ws'), isFalse);
      expect(mock.isDtdUri('ws://127.0.0.1:8181/auth_token/ws/'), isFalse);

      // DTD uris
      expect(mock.isDtdUri('http://127.0.0.1:8181'), isTrue);
      expect(mock.isDtdUri('http://127.0.0.1:8181/mock-secret-token'), isTrue);
    });

    test('normalizeToWsUri converts http/https/ws schemes properly', () {
      expect(mock.normalizeToWsUri('http://127.0.0.1:8181/token/'),
          equals('ws://127.0.0.1:8181/token/ws'));
      expect(mock.normalizeToWsUri('https://127.0.0.1:8181/token'),
          equals('wss://127.0.0.1:8181/token/ws'));
      expect(mock.normalizeToWsUri('ws://127.0.0.1:8181/token'),
          equals('ws://127.0.0.1:8181/token/ws'));
    });

    test('formatBytes formatting sizes', () {
      expect(mock.formatBytes(0), equals('0 B'));
      expect(mock.formatBytes(1023), equals('1023.00 B'));
      expect(mock.formatBytes(1024), equals('1.00 KB'));
      expect(mock.formatBytes(1024 * 1024), equals('1.00 MB'));
      expect(mock.formatBytes(1024 * 1024 * 1024), equals('1.00 GB'));
      expect(mock.formatBytes(-512), equals('-512.00 B'));
    });

    test('serializeDualFormat formats as json when preferred', () {
      mock.responseFormat = 'json';
      final res = mock.serializeDualFormat(
        title: 'Title',
        markdownBody: 'Body',
        structuredData: {'key': 'value'},
      );

      expect(res.isError, isNot(isTrue));
      final text = (res.content.first as TextContent).text;
      expect(text, contains('```json'));
      expect(text, contains('"key": "value"'));
    });

    test('serializeDualFormat formats as markdown when preferred', () {
      mock.responseFormat = 'markdown';
      final res = mock.serializeDualFormat(
        title: 'Title',
        markdownBody: 'Body',
        structuredData: {'key': 'value'},
      );

      expect(res.isError, isNot(isTrue));
      final text = (res.content.first as TextContent).text;
      expect(text, startsWith('Title'));
      expect(text, contains('Body'));
    });

    test('limitSchema returns IntegerSchema and defaults', () {
      final schema = mock.limitSchema(defaultValue: 50, max: 100);
      expect(schema, isA<IntegerSchema>());
      expect(schema.description, contains('default: 50'));
      expect(schema.description, contains('max: 100'));
    });
  });

  group('ConnectionSupport Edge Cases', () {
    late StreamChannelController<String> controller;
    late ConnectionSupportEdgeMock edgeMock;

    setUp(() {
      controller = StreamChannelController<String>();
      edgeMock = ConnectionSupportEdgeMock(controller.local);
      edgeMock.registerConnectionTools();
    });

    test('connect tool with malformed URI returns validation error', () async {
      final result = await edgeMock.callTool(
        CallToolRequest(
          name: McpTool.connection.name,
          arguments: const {
            'action': 'connect',
            'uri': 'ftp://127.0.0.1:8181', // Invalid scheme
            'workspace_root': '/some/path',
          },
        ),
      );

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Invalid URI scheme'));
    });

    test('connect tool with missing uri and vmServiceUri returns error',
        () async {
      final result = await edgeMock.callTool(
        CallToolRequest(
          name: McpTool.connection.name,
          arguments: const {
            'action': 'connect',
            'workspace_root': '/some/path',
          },
        ),
      );
      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text,
          contains('Required parameter "uri" or "vmServiceUri" is missing.'));
    });

    test('connect_dtd tool with missing uri and vmServiceUri returns error',
        () async {
      final result = await edgeMock.callTool(
        CallToolRequest(
          name: McpTool.connection.name,
          arguments: const {
            'action': 'connect_dtd',
          },
        ),
      );
      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(
          text, contains('Missing required argument "uri" or "vmServiceUri"'));
    });

    test('connect_dtd tool with dummy URI returns connection error', () async {
      final result = await edgeMock.callTool(
        CallToolRequest(
          name: McpTool.connection.name,
          arguments: const {
            'action': 'connect_dtd',
            'uri': 'ws://127.0.0.1:9999',
          },
        ),
      );
      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Failed to connect to DTD'));
    });

    test('disconnect tool when not connected is successful and no-op',
        () async {
      edgeMock.vmService = null;

      final result = await edgeMock.callTool(
        CallToolRequest(
          name: McpTool.connection.name,
          arguments: const {
            'action': 'disconnect',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Not connected to any VM Service app'));
    });
  });
}

base class ConnectionSupportEdgeMock extends MCPServer
    with
        ToolsSupport,
        LoggingSupport,
        RootsTrackingSupport,
        VmConnectionSupport,
        ConsoleLoggingSupport,
        ConnectionSupport {
  ConnectionSupportEdgeMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}
