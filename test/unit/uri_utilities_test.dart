import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

final class TestVmConnectionSupport extends MCPServer
    with ToolsSupport, VmConnectionSupport {
  TestVmConnectionSupport()
      : super.fromStreamChannel(
          StreamChannel<String>(
            StreamController<String>().stream,
            StreamController<String>().sink,
          ),
          implementation: Implementation(name: 'test', version: '1.0.0'),
        );
}

void main() {
  final support = TestVmConnectionSupport();

  group('isDtdUri', () {
    test('identifies direct VM Service URIs', () {
      expect(support.isDtdUri('ws://127.0.0.1:8181/auth_token=/ws'), isFalse);
      expect(
        support.isDtdUri('http://127.0.0.1:8181/auth_token=/ws/'),
        isFalse,
      );
      expect(
        support.isDtdUri('http://127.0.0.1:8181/ws?auth_token=abc'),
        isFalse,
      );
      expect(support.isDtdUri('http://127.0.0.1:8181/auth_token=xyz'), isFalse);
    });

    test('identifies DTD URIs', () {
      expect(support.isDtdUri('ws://127.0.0.1:6262'), isTrue);
      expect(support.isDtdUri('http://127.0.0.1:6262/'), isTrue);
      expect(support.isDtdUri('127.0.0.1:6262'), isTrue);
    });
  });

  group('normalizeToWsUri', () {
    test('converts http/https to ws/wss', () {
      expect(
        support.normalizeToWsUri('http://127.0.0.1:8181/auth_token=/ws'),
        equals('ws://127.0.0.1:8181/auth_token=/ws'),
      );
      expect(
        support.normalizeToWsUri('https://127.0.0.1:8181/auth_token=/ws'),
        equals('wss://127.0.0.1:8181/auth_token=/ws'),
      );
    });

    test('leaves ws/wss unchanged', () {
      expect(
        support.normalizeToWsUri('ws://127.0.0.1:8181/auth_token=/ws'),
        equals('ws://127.0.0.1:8181/auth_token=/ws'),
      );
      expect(
        support.normalizeToWsUri('wss://127.0.0.1:8181/auth_token=/ws'),
        equals('wss://127.0.0.1:8181/auth_token=/ws'),
      );
    });

    test('adds /ws suffix to direct VM Service URIs if missing', () {
      expect(
        support.normalizeToWsUri('http://127.0.0.1:8181/auth_token='),
        equals('ws://127.0.0.1:8181/auth_token=/ws'),
      );
    });

    test('does not add /ws suffix to DTD URIs', () {
      expect(
        support.normalizeToWsUri('http://127.0.0.1:6262'),
        equals('ws://127.0.0.1:6262'),
      );
    });
  });
}
