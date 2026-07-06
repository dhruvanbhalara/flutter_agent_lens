import 'dart:io';
import 'package:dart_mcp/server.dart';

/// Standardized tool error handler helper.
CallToolResult handleToolError(
    Object error, StackTrace stack, String toolName) {
  stderr.writeln('[mcp:$toolName] ERROR: $error');
  stderr.writeln('[mcp:$toolName] STACKTRACE: $stack');
  return CallToolResult(
    content: [
      TextContent(text: '$toolName execution failed: $error'),
    ],
    isError: true,
  );
}
