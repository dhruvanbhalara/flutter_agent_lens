import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import '../enums/mcp_tool.dart';
import 'vm_connection_support.dart';

/// Support mixin providing tools for fetching and statefully buffering console
/// stdout, stderr, and developer log streams from the connected application.
base mixin ConsoleLoggingSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Local buffer of the most recent console logs.
  final List<String> logBuffer = [];

  /// Last log line received, used for deduplication.
  String? lastLogLine;

  /// Counter for duplicate consecutive logs.
  int duplicateLogCount = 0;

  /// Subscription to the VM Service's stdout stream.
  StreamSubscription? stdoutSub;

  /// Subscription to the VM Service's stderr stream.
  StreamSubscription? stderrSub;

  /// Subscription to the VM Service's logging/developer stream.
  StreamSubscription? loggingSub;

  /// Registers the console log retrieval tool.
  void registerLoggingTools() {
    registerTool(
      Tool(
        name: McpTool.fetchConsoleLogs.name,
        description:
            'Read recent console logs from stdout, stderr, and developer streams.',
        inputSchema: ObjectSchema(
          properties: {
            'limit': limitSchema(defaultValue: 50.0),
            'format': StringSchema(
              description:
                  'Response format: markdown or json (default: markdown).',
            ),
          },
        ),
      ),
      _handleFetchConsoleLogs,
    );
  }

  /// Starts listening to and buffering stdout, stderr, and logging streams.
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

  /// Formats and adds a new log message to the log buffer, deduplicating identical lines.
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

  /// Cancels all active log stream subscriptions and resets state.
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

  /// Subscribes to a VM service stream producing base64-encoded byte buffers (stdout/stderr).
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
          } catch (e) {
            stderr.writeln('[mcp:logging] Error decoding byte stream: $e');
          }
        }
      });
    } catch (e) {
      stderr.writeln(
          '[mcp:logging] Error listening to byte stream $streamId: $e');
      return null;
    }
  }

  /// Handles the fetch_console_logs tool request.
  Future<CallToolResult> _handleFetchConsoleLogs(CallToolRequest req) async {
    final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 50;
    final maxLimit = limit.clamp(1, 200);
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
