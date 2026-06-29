import 'dart:async';
import 'package:stream_channel/stream_channel.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:test/test.dart';
import 'package:dart_mcp/server.dart';

// Create a concrete class implementing VmConnectionSupport to test it.
final class TestVmConnectionSupport extends MCPServer
    with ToolsSupport, VmConnectionSupport {
  TestVmConnectionSupport()
      : super.fromStreamChannel(
          StreamChannel<String>(StreamController<String>().stream,
              StreamController<String>().sink),
          implementation: Implementation(name: 'test', version: '1.0.0'),
        );
}

void main() {
  final support = TestVmConnectionSupport();

  group('formatBytes', () {
    test('formats 0 bytes', () {
      expect(support.formatBytes(0), equals('0 B'));
    });

    test('formats bytes below 1KB', () {
      expect(support.formatBytes(500), equals('500.00 B'));
      expect(support.formatBytes(1023), equals('1023.00 B'));
    });

    test('formats kilobytes', () {
      expect(support.formatBytes(1024), equals('1.00 KB'));
      expect(support.formatBytes(1536), equals('1.50 KB'));
      expect(support.formatBytes(1048575), equals('1024.00 KB'));
    });

    test('formats megabytes', () {
      expect(support.formatBytes(1048576), equals('1.00 MB'));
      expect(support.formatBytes(1048576 * 5), equals('5.00 MB'));
    });

    test('formats gigabytes', () {
      expect(support.formatBytes(1073741824), equals('1.00 GB'));
    });

    test('formats negative bytes', () {
      expect(support.formatBytes(-1024), equals('-1.00 KB'));
    });
  });
}
