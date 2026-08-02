import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/utils/string_utils.dart';
import 'package:test/test.dart';

void main() {
  group('String Utilities Tests', () {
    test('truncateString edge cases', () {
      expect(truncateString('hello', maxLength: 10), equals('hello'));
      expect(truncateString('hello', maxLength: 5), equals('hello'));
      expect(
        truncateString('hello world', maxLength: 5),
        equals('hello\n... [TRUNCATED - 6 characters omitted]'),
      );
      expect(truncateString('', maxLength: 5), equals(''));
    });

    test('formatBytes handles zero, byte, KB, MB ranges and negatives', () {
      expect(formatBytes(0), equals('0 B'));
      expect(formatBytes(512), equals('512.00 B'));
      expect(formatBytes(1024), equals('1.00 KB'));
      expect(formatBytes(1536), equals('1.50 KB'));
      expect(formatBytes(1024 * 1024), equals('1.00 MB'));
      expect(formatBytes(-1024), equals('-1.00 KB'));
    });
  });

  group('CallToolRequestX Extension Tests', () {
    test('arg retrieves present and correctly typed argument', () {
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: {'strKey': 'stringValue', 'intKey': 42},
      );

      expect(req.arg<String>('strKey'), equals('stringValue'));
      expect(req.arg<int>('intKey'), equals(42));
      expect(req.arg<double>('intKey'), isNull);
    });

    test('arg returns null on absent key or missing arguments map', () {
      final req1 = CallToolRequest(name: 'test_tool');
      expect(req1.arg<String>('someKey'), isNull);

      final req2 =
          CallToolRequest(name: 'test_tool', arguments: {'key': 'value'});
      expect(req2.arg<String>('absentKey'), isNull);
    });

    test('requireArg retrieves present argument', () {
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: {'strKey': 'value', 'nullableKey': null},
      );

      expect(req.requireArg<String>('strKey'), equals('value'));
    });

    test('requireArg throws on missing arguments map or key', () {
      final req1 = CallToolRequest(name: 'test_tool');
      expect(() => req1.requireArg<String>('key'), throwsArgumentError);

      final req2 =
          CallToolRequest(name: 'test_tool', arguments: {'key': 'value'});
      expect(() => req2.requireArg<String>('absentKey'), throwsArgumentError);
    });

    test('requireArg throws on type mismatch', () {
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: {'key': 42},
      );
      expect(() => req.requireArg<String>('key'), throwsArgumentError);
    });

    test('requireArg handles nullable types successfully', () {
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: {'nullableKey': null},
      );
      expect(req.requireArg<String?>('nullableKey'), isNull);
    });
  });
}
