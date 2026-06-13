part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for capturing console, stdout, stderr, and logging streams.
extension LoggingHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleFetchConsoleLogs(CallToolRequest req) async {
    final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 50;
    final maxLimit = limit > 200 ? 200 : (limit < 1 ? 1 : limit);
    stderr.writeln(
        '[mcp:fetch_console_logs] Fetching logs, buffer size=${_logBuffer.length}, limit=$maxLimit');

    final totalLines = _logBuffer.length;
    final startIndex = totalLines > maxLimit ? totalLines - maxLimit : 0;
    final recentLogs = _logBuffer.sublist(startIndex);

    final mdBuffer = StringBuffer('### Recent Console Logs\n\n');
    if (recentLogs.isEmpty) {
      mdBuffer.writeln('No console logs buffered yet.');
    } else {
      mdBuffer.writeln('```text');
      for (final log in recentLogs) {
        mdBuffer.writeln(log);
      }
      mdBuffer.writeln('```');
    }

    return _serializeDualFormat(
      title: '### Console Log Cache',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'total_buffered_lines': totalLines,
        'returned_lines': recentLogs.length,
        'logs': recentLogs,
      },
    );
  }
}
