// Testing deprecated class for backward compatibility.
// ignore_for_file: deprecated_member_use_from_same_package
import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/utils/string_utils.dart';
import 'package:test/test.dart';

void main() {
  group('StringUtils Tests', () {
    test('truncate edge cases', () {
      expect(StringUtils.truncate('hello', maxLength: 10), equals('hello'));
      expect(StringUtils.truncate('hello', maxLength: 5), equals('hello'));
      expect(
        StringUtils.truncate('hello world', maxLength: 5),
        equals('hello\n... [TRUNCATED - 6 characters omitted]'),
      );
      expect(StringUtils.truncate('', maxLength: 5), equals(''));
    });

    test('formatMap basic and edge cases', () {
      final map = {
        'key1': 'value1',
        'key2': {
          'nestedKey': 'nestedValue',
        },
        'listKey': [1, 2, 3],
        'longList': List.generate(15, (i) => i),
      };

      final formatted = StringUtils.formatMap(map);
      expect(formatted, contains('"key1": "value1"'));
      expect(formatted, contains('"nestedKey": "nestedValue"'));
      expect(formatted, contains('[1, 2, 3]'));
      expect(formatted, contains('[0, ... (14 more items)]'));
    });

    test('formatMap max depth limit', () {
      final map = {
        'a': {
          'b': {
            'c': {
              'd': 'value',
            }
          }
        }
      };
      final formatted = StringUtils.formatMap(map, maxDepth: 2);
      expect(formatted, contains('{...}'));
      expect(formatted, isNot(contains('"d"')));
    });

    test('top-level truncateString edge cases', () {
      expect(truncateString('hello', maxLength: 10), equals('hello'));
      expect(truncateString('hello', maxLength: 5), equals('hello'));
      expect(
        truncateString('hello world', maxLength: 5),
        equals('hello\n... [TRUNCATED - 6 characters omitted]'),
      );
      expect(truncateString('', maxLength: 5), equals(''));
    });

    test('top-level formatMapString basic and edge cases', () {
      final map = {
        'key1': 'value1',
        'key2': {
          'nestedKey': 'nestedValue',
        },
        'listKey': [1, 2, 3],
        'longList': List.generate(15, (i) => i),
      };

      final formatted = formatMapString(map);
      expect(formatted, contains('"key1": "value1"'));
      expect(formatted, contains('"nestedKey": "nestedValue"'));
      expect(formatted, contains('[1, 2, 3]'));
      expect(formatted, contains('[0, ... (14 more items)]'));
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
