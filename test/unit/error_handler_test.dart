import 'package:test/test.dart';
import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/utils/tool_error_handler.dart';

void main() {
  group('ToolErrorHandler Tests', () {
    test(
        'handleToolError captures FormatException and returns standard error result',
        () {
      final result = handleToolError(
        const FormatException('Invalid JSON input'),
        StackTrace.current,
        'test_tool',
      );

      expect(result.isError, isTrue);
      expect(result.content, isNotEmpty);
      final textContent = result.content.first as TextContent;
      expect(textContent.text, contains('FormatException: Invalid JSON input'));
      expect(textContent.text, contains('test_tool execution failed:'));
    });

    test(
        'handleToolError captures StateError and returns standard error result',
        () {
      final result = handleToolError(
        StateError('Not connected'),
        StackTrace.current,
        'disconnect',
      );

      expect(result.isError, isTrue);
      expect(result.content, isNotEmpty);
      final textContent = result.content.first as TextContent;
      expect(textContent.text, contains('Bad state: Not connected'));
      expect(textContent.text, contains('disconnect execution failed:'));
    });
  });
}
