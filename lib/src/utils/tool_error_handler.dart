import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/action_enum.dart';

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

/// Returns an error [CallToolResult] for an unrecognized action string.
///
/// Use this to replace the repeated null-check-and-error pattern after
/// calling an action enum's `fromString`.
CallToolResult unknownActionError<T extends ActionEnum>(
  String actionStr,
  List<T> values,
  String toolLabel,
) {
  return CallToolResult(
    content: [
      TextContent(
        text: 'Unknown $toolLabel action: $actionStr. Valid actions: '
            '${values.map((e) => e.value).join(", ")}',
      ),
    ],
    isError: true,
  );
}
