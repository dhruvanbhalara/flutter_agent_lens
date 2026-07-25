import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:vm_service/vm_service.dart';

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
  StreamSubscription<Event>? stdoutSub;

  /// Subscription to the VM Service's stderr stream.
  StreamSubscription<Event>? stderrSub;

  /// Subscription to the VM Service's logging/developer stream.
  StreamSubscription<Event>? loggingSub;

  /// Optional callback invoked when new log entries are formatted and added.
  void Function(String line)? _watchLogCallback;

  /// Registers the console log tools.
  void registerLoggingTools() {
    registerTool(
      Tool(
        name: McpTool.consoleLogs.name,
        description: 'Manage console logs. '
            'Actions: fetch (read buffered logs), '
            'watch (stream live logs over a duration window).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description: 'Action to perform: fetch, watch. Default: fetch.',
            ),
            'limit': limitSchema(defaultValue: 50),
            'duration_seconds': durationSchema(defaultValue: 5.0),
            'filter': StringSchema(
              description: 'Optional text filter substring for watch action.',
            ),
          },
        ),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: false,
        ),
      ),
      _handleConsoleLogs,
    );
  }

  static final RegExp _newlineRegExp = RegExp(r'\r?\n');

  /// Starts listening to and buffering stdout, stderr, and logging streams.
  Future<void> startLogging() async {
    await cleanupLogging();
    logBuffer.clear();

    final service = vmService;
    if (service == null) return;

    try {
      stdoutSub = await _listenToByteStream(
          EventStreams.kStdout, '[STDOUT]', service.onStdoutEvent);
    } catch (e) {
      stderr.writeln('[mcp:logging] Error starting stdout listener: $e');
    }

    try {
      stderrSub = await _listenToByteStream(
          EventStreams.kStderr, '[STDERR]', service.onStderrEvent);
    } catch (e) {
      stderr.writeln('[mcp:logging] Error starting stderr listener: $e');
    }

    try {
      await service.streamListen(EventStreams.kLogging);
      loggingSub = service.onLoggingEvent.listen((Event event) {
        final logRecord = event.logRecord;
        if (logRecord != null) {
          final messageRef = logRecord.message;
          final value = messageRef?.valueAsString ?? '';
          final loggerName = logRecord.loggerName?.valueAsString ?? 'log';
          addToLogBuffer('[$loggerName]', value);
        }
      });
    } on RPCError catch (e) {
      if (e.code != 103) {
        stderr.writeln('[mcp:logging] Error subscribing to logging stream: $e');
      }
    } catch (e) {
      stderr.writeln('[mcp:logging] Error subscribing to logging stream: $e');
    }
  }

  /// Formats and adds a new log message to the log buffer, deduplicating identical lines.
  void addToLogBuffer(String prefix, String message) {
    final lines = message.split(_newlineRegExp);
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
      _watchLogCallback?.call(formatted);
    }
    if (logBuffer.length > 200) {
      logBuffer.removeRange(0, logBuffer.length - 200);
    }
  }

  /// Cancels all active log stream subscriptions and resets state.
  Future<void> cleanupLogging() async {
    final futures = <Future<void>>[
      if (stdoutSub != null) stdoutSub!.cancel(),
      if (stderrSub != null) stderrSub!.cancel(),
      if (loggingSub != null) loggingSub!.cancel(),
    ];
    await Future.wait<void>(futures);
    stdoutSub = null;
    stderrSub = null;
    loggingSub = null;
    lastLogLine = null;
    duplicateLogCount = 0;
  }

  /// Subscribes to a VM service stream producing base64-encoded byte buffers (stdout/stderr).
  Future<StreamSubscription<Event>?> _listenToByteStream(
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
    } on RPCError catch (e) {
      if (e.code != 103) {
        stderr.writeln(
            '[mcp:logging] Error subscribing to byte stream $streamId: $e');
      }
    } catch (e) {
      stderr.writeln(
          '[mcp:logging] Error subscribing to byte stream $streamId: $e');
    }
    return null;
  }

  /// Handles the console_logs composite tool request.
  Future<CallToolResult> _handleConsoleLogs(CallToolRequest req) async {
    final action = req.arg<String>('action') ?? 'fetch';
    return switch (action) {
      'fetch' => _handleFetchConsoleLogs(req),
      'watch' => _handleWatchLogs(req),
      _ => CallToolResult(
          content: [TextContent(text: 'Unknown console_logs action: $action')],
          isError: true,
        ),
    };
  }

  /// Handles the fetch action for console_logs.
  Future<CallToolResult> _handleFetchConsoleLogs(CallToolRequest req) async {
    final limit = (req.arg<num>('limit'))?.toInt() ?? 50;
    final maxLimit = limit.clamp(1, 200);
    stderr.writeln(
        '[mcp:console_logs] Fetching logs, buffer size=${logBuffer.length}, limit=$maxLimit');

    final totalLines = logBuffer.length;
    final startIndex = totalLines > maxLimit ? totalLines - maxLimit : 0;
    final recentLogs = logBuffer.sublist(startIndex);

    final mdBuffer = StringBuffer('Recent Console Logs\n\n');
    if (recentLogs.isEmpty) {
      mdBuffer.writeln('No console logs buffered yet.');
    } else {
      recentLogs.forEach(mdBuffer.writeln);
    }

    return serializeDualFormat(
      title: 'Console Log Cache',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'total_buffered_lines': totalLines,
        'returned_lines': recentLogs.length,
        'logs': recentLogs,
      },
    );
  }

  /// Handles watching live console logs over a specified duration window.
  Future<CallToolResult> _handleWatchLogs(CallToolRequest req) async {
    final rawDuration = req.arg<num>('duration_seconds') ?? 5;
    final duration = rawDuration.toInt().clamp(1, 30);
    final filter = req.arg<String>('filter');

    stderr.writeln(
        '[mcp:watch_logs] Watching logs for ${duration}s, filter="$filter"');

    final watchBuffer = <String>[];
    _watchLogCallback = watchBuffer.add;

    try {
      await Future<void>.delayed(Duration(seconds: duration));
    } finally {
      _watchLogCallback = null;
    }

    final List<String> matchingLogs;
    if (filter != null && filter.isNotEmpty) {
      final lowerFilter = filter.toLowerCase();
      matchingLogs = watchBuffer
          .where((line) => line.toLowerCase().contains(lowerFilter))
          .toList();
    } else {
      matchingLogs = watchBuffer;
    }

    final mdBuffer =
        StringBuffer('Live Console Logs ($duration s duration window)\n\n');
    if (matchingLogs.isEmpty) {
      mdBuffer.writeln('No matching logs received during watch window.');
    } else {
      matchingLogs.forEach(mdBuffer.writeln);
    }

    return serializeDualFormat(
      title: 'Live Console Logs',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'duration_seconds': duration,
        if (filter != null && filter.isNotEmpty) 'filter': filter,
        'total_captured_lines': watchBuffer.length,
        'returned_lines': matchingLogs.length,
        'logs': matchingLogs,
      },
    );
  }
}
