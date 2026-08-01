import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:test/test.dart';

void main() {
  group('CallToolRequestX', () {
    test('intArg extracts and converts int and double values', () {
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: {'count': 10, 'ratio': 4.75},
      );

      expect(req.intArg('count'), equals(10));
      expect(req.intArg('ratio'), equals(4));
      expect(req.intArg('missing', defaultValue: 5), equals(5));
      expect(req.intArg('missing'), isNull);
    });

    test('doubleArg extracts and converts numeric values', () {
      final req = CallToolRequest(
        name: 'test_tool',
        arguments: {'val1': 12, 'val2': 3.14},
      );

      expect(req.doubleArg('val1'), equals(12.0));
      expect(req.doubleArg('val2'), equals(3.14));
      expect(req.doubleArg('missing', defaultValue: 1.5), equals(1.5));
      expect(req.doubleArg('missing'), isNull);
    });
  });
}
