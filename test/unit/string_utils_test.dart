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
        contains('[TRUNCATED - 6 characters omitted'),
      );
      expect(truncateString('', maxLength: 5), equals(''));
    });

    test('formatMapString basic and edge cases', () {
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

    test('formatBytes formatting sizes', () {
      expect(formatBytes(0), equals('0 B'));
      expect(formatBytes(1023), equals('1023.00 B'));
      expect(formatBytes(1024), equals('1.00 KB'));
      expect(formatBytes(1024 * 1024), equals('1.00 MB'));
      expect(formatBytes(1024 * 1024 * 1024), equals('1.00 GB'));
      expect(formatBytes(-512), equals('-512.00 B'));
    });

    test('formatRelativePath strips workspaceRoot and formats paths', () {
      expect(
        formatRelativePath(
            '/Users/dev/project/lib/main.dart', '/Users/dev/project'),
        equals('lib/main.dart'),
      );
      expect(
        formatRelativePath('file:///Users/dev/project/lib/widgets/card.dart',
            '/Users/dev/project'),
        equals('lib/widgets/card.dart'),
      );
      expect(
        formatRelativePath(
            'package:flutter/material.dart', '/Users/dev/project'),
        equals('package:flutter/material.dart'),
      );
      expect(
        formatRelativePath('/other/path/file.dart', '/Users/dev/project'),
        equals('/other/path/file.dart'),
      );
      expect(
        formatRelativePath('/Users/dev/project/lib/main.dart', null),
        equals('/Users/dev/project/lib/main.dart'),
      );
      expect(
        formatRelativePath('', '/Users/dev/project'),
        equals(''),
      );
    });

    test('compactCollection caps list at maxItems', () {
      final items = [1, 2, 3, 4, 5];
      expect(compactCollection(items, maxItems: 3), equals([1, 2, 3]));
      expect(compactCollection(items, maxItems: 10), equals([1, 2, 3, 4, 5]));
    });

    test('truncateString respects full: true bypass', () {
      final longString = 'a' * 20000;
      expect(truncateString(longString, maxLength: 5000, full: true),
          equals(longString));
      expect(
          truncateString(longString, maxLength: 5000), contains('[TRUNCATED'));
    });

    test('compactCollection respects full: true bypass', () {
      final items = List.generate(50, (i) => i);
      expect(compactCollection(items, full: true).length, equals(50));
      expect(compactCollection(items).length, equals(20));
    });

    test('compactStructuredData compacts lists inside map unless full: true',
        () {
      final data = {
        'count': 100,
        'items': List.generate(50, (i) => 'item_$i'),
        'nested': {
          'sub_items': List.generate(30, (i) => i),
        }
      };

      final compacted = compactStructuredData(data, maxItems: 10);
      expect((compacted!['items']! as List).length, equals(10));
      expect(((compacted['nested']! as Map)['sub_items']! as List).length,
          equals(10));

      final fullData = compactStructuredData(data, maxItems: 10, full: true);
      expect((fullData!['items']! as List).length, equals(50));
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
