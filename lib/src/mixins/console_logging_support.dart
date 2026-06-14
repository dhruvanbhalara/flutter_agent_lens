import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import 'vm_connection_support.dart';

base mixin ConsoleLoggingSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  final List<String> logBuffer = [];
  String? lastLogLine;
  int duplicateLogCount = 0;
  StreamSubscription? stdoutSub;
  StreamSubscription? stderrSub;
  StreamSubscription? loggingSub;

  void registerLoggingTools() {
    registerTool(
      Tool(
        name: 'fetch_console_logs',
        description:
            'Read recent console logs from stdout, stderr, and developer streams.',
        inputSchema: ObjectSchema(
          properties: {
            'limit': limitSchema(defaultValue: 50.0),
            'format': StringSchema(
              description:
                  'Response format: markdown, json, or dual (default: markdown).',
            ),
          },
        ),
      ),
      wrapToolCall('fetch_console_logs', _handleFetchConsoleLogs),
    );
  }

  void startLogging() {
    cleanupLogging();
    logBuffer.clear();

    if (vmService == null) return;

    // Subscribe to stdout and stderr streams using helper
    _listenToByteStream(
            EventStreams.kStdout, '[STDOUT]', vmService!.onStdoutEvent)
        .then((sub) => stdoutSub = sub);
    _listenToByteStream(
            EventStreams.kStderr, '[STDERR]', vmService!.onStderrEvent)
        .then((sub) => stderrSub = sub);

    // Subscribe to developer logs stream
    vmService!.streamListen(EventStreams.kLogging).then((_) {
      loggingSub = vmService!.onLoggingEvent.listen((Event event) {
        final logRecord = event.logRecord;
        if (logRecord != null) {
          final messageRef = logRecord.message;
          final value = messageRef?.valueAsString ?? '';
          final loggerName = logRecord.loggerName?.valueAsString ?? 'log';
          addToLogBuffer('[$loggerName]', value);
        }
      });
    }).catchError((_) {});
  }

  void addToLogBuffer(String prefix, String message) {
    final lines = message.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final formatted = '$prefix $trimmed';
      if (formatted == lastLogLine) {
        duplicateLogCount++;
        if (logBuffer.isNotEmpty) {
          logBuffer.removeLast();
        }
        logBuffer.add('$formatted (repeated ${duplicateLogCount + 1} times)');
      } else {
        lastLogLine = formatted;
        duplicateLogCount = 0;
        logBuffer.add(formatted);
      }
    }
    if (logBuffer.length > 200) {
      logBuffer.removeRange(0, logBuffer.length - 200);
    }
  }

  void cleanupLogging() {
    stdoutSub?.cancel();
    stderrSub?.cancel();
    loggingSub?.cancel();
    stdoutSub = null;
    stderrSub = null;
    loggingSub = null;
    lastLogLine = null;
    duplicateLogCount = 0;
  }

  Future<StreamSubscription?> _listenToByteStream(
    String streamId,
    String logPrefix,
    Stream<Event> eventStream,
  ) async {
    if (vmService == null) return null;
    try {
      await vmService!.streamListen(streamId);
      return eventStream.listen((Event event) {
        final bytes = event.bytes;
        if (bytes != null) {
          try {
            final decoded = utf8.decode(base64.decode(bytes));
            addToLogBuffer(logPrefix, decoded);
          } catch (_) {}
        }
      });
    } catch (_) {
      return null;
    }
  }

  Future<CallToolResult> _handleFetchConsoleLogs(CallToolRequest req) async {
    final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 50;
    final maxLimit = limit > 200 ? 200 : (limit < 1 ? 1 : limit);
    stderr.writeln(
        '[mcp:fetch_console_logs] Fetching logs, buffer size=${logBuffer.length}, limit=$maxLimit');

    final totalLines = logBuffer.length;
    final startIndex = totalLines > maxLimit ? totalLines - maxLimit : 0;
    final recentLogs = logBuffer.sublist(startIndex);

    final mdBuffer = StringBuffer('Recent Console Logs\n\n');
    if (recentLogs.isEmpty) {
      mdBuffer.writeln('No console logs buffered yet.');
    } else {
      for (final log in recentLogs) {
        mdBuffer.writeln(log);
      }
    }

    return serializeDualFormat(
      title: 'Console Log Cache',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'total_buffered_lines': totalLines,
        'returned_lines': recentLogs.length,
        'logs': recentLogs,
      },
      format: req.arguments?['format'] as String?,
    );
  }
}
