import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';

/// Standardized tool error handler helper.
CallToolResult handleToolError(
  Object error,
  StackTrace stack,
  String toolName,
) {
  stderr.writeln('[mcp:$toolName] ERROR: $error');
  stderr.writeln('[mcp:$toolName] STACKTRACE: $stack');
  return CallToolResult(
    content: [TextContent(text: '$toolName execution failed: $error')],
    isError: true,
  );
}

/// Safely executes a tool operation with error logging and standardized error response.
Future<CallToolResult> safeToolCall({
  required String toolName,
  required Future<CallToolResult> Function() action,
}) async {
  try {
    return await action();
  } catch (error, stack) {
    return handleToolError(error, stack, toolName);
  }
}
