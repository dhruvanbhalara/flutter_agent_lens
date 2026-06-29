import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:vm_service/vm_service.dart';

/// Support mixin providing tools for capturing and analyzing HTTP traffic details.
base mixin NetworkCaptureSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Whether the network capture session is statefully active.
  bool isCapturingNetwork = false;

  /// Timestamp in milliseconds when the network capture session was started.
  int? networkCaptureStartTime;

  /// Cache of statefully captured requests, indexed by request ID.
  final Map<String, Map<String, dynamic>> capturedRequests = {};

  /// Subscription to the VM Service's extension event stream.
  StreamSubscription? networkExtensionSub;

  /// Subscription to the VM Service's log event stream.
  StreamSubscription? networkLoggingSub;

  /// Registers all network capture and diagnostic tools.
  void registerNetworkTools() {
    registerTool(
      Tool(
        name: McpTool.getNetworkProfile.name,
        description:
            'Read the current HTTP network requests profile history from the VM.',
        inputSchema: ObjectSchema(
          properties: {
            'includeRawResponse': BooleanSchema(
              description:
                  'Whether to include the raw JSON-RPC response in structured data (default: false).',
            ),
            'format': formatSchema,
          },
        ),
      ),
      _handleGetNetworkProfile,
    );

    registerTool(
      Tool(
        name: McpTool.startNetworkCapture.name,
        description:
            'Start a stateful session to capture HTTP network traffic.',
        inputSchema: emptySchema(),
      ),
      _handleStartNetworkCapture,
    );

    registerTool(
      Tool(
        name: McpTool.stopNetworkCapture.name,
        description:
            'Stop the active network capture session and get the traffic report.',
        inputSchema: ObjectSchema(
          properties: {
            'sortBy': StringSchema(
              description:
                  'Sort requests by (time, duration, size; default: time).',
            ),
            'includeRawResponse': BooleanSchema(
              description:
                  'Whether to include the full raw network requests response in the structured data (default: false).',
            ),
            'format': formatSchema,
          },
        ),
      ),
      _handleStopNetworkCapture,
    );
  }

  /// Disposes active stream subscriptions and clears stateful captured requests.
  void cleanupNetworkCapture() {
    networkExtensionSub?.cancel();
    networkExtensionSub = null;
    networkLoggingSub?.cancel();
    networkLoggingSub = null;
    isCapturingNetwork = false;
    networkCaptureStartTime = null;
    capturedRequests.clear();
  }

  /// Handles the get_network_profile tool request.
  Future<CallToolResult> _handleGetNetworkProfile(CallToolRequest req) async {
    stderr.writeln('[mcp:network_profile] Fetching HTTP profile...');
    final response = await vmService!.callServiceExtension(
      'ext.dart.io.getHttpProfile',
      isolateId: isolateId,
    );

    final rawResult = response.json?['result'];
    Map<String, dynamic> result;
    if (rawResult is String) {
      result = jsonDecode(rawResult) as Map<String, dynamic>;
    } else if (rawResult is Map) {
      result = Map<String, dynamic>.from(rawResult);
    } else {
      result = {};
    }

    final requestsList = result['requests'] as List<dynamic>? ?? [];
    stderr
        .writeln('[mcp:network_profile] Found ${requestsList.length} requests');
    final formattedRequests = <Map<String, dynamic>>[];
    final md = StringBuffer('Network HTTP Profile History\n\n');

    if (requestsList.isEmpty) {
      md.writeln('No network requests recorded.');
    } else {
      md.writeln(
        '| ID | Method | URI | Status | Duration | Req Size | Res Size | Start Time |',
      );
      md.writeln('| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |');

      for (final reqObj in requestsList) {
        if (reqObj is Map<String, dynamic>) {
          final id = reqObj['id']?.toString() ?? 'N/A';
          final method = reqObj['method']?.toString() ?? 'N/A';
          final uri = reqObj['uri']?.toString() ?? 'N/A';

          final requestData = reqObj['request'] as Map<String, dynamic>?;
          final responseData = reqObj['response'] as Map<String, dynamic>?;

          final statusCode =
              responseData?['statusCode']?.toString() ?? 'Pending';

          final startTimeUs = reqObj['startTime'] as int?;
          final endTimeUs = reqObj['endTime'] as int?;
          var durationStr = 'Pending';
          if (startTimeUs != null && endTimeUs != null) {
            final durationMs = (endTimeUs - startTimeUs) / 1000.0;
            durationStr = '${durationMs.toStringAsFixed(1)} ms';
          }

          var startTimeStr = 'Unknown';
          if (startTimeUs != null) {
            final dt = DateTime.fromMicrosecondsSinceEpoch(startTimeUs);
            startTimeStr =
                dt.toIso8601String().split('T').last.substring(0, 12);
          }

          final reqSize = requestData?['contentLength'] ?? 0;
          final resSize = responseData?['contentLength'] ?? 0;

          final displayUri =
              uri.length > 50 ? '${uri.substring(0, 47)}...' : uri;

          md.writeln(
            '| `$id` | $method | `$displayUri` | `$statusCode` | $durationStr | $reqSize B | $resSize B | $startTimeStr |',
          );

          formattedRequests.add({
            'id': id,
            'method': method,
            'uri': uri,
            'statusCode': statusCode,
            'duration_ms': startTimeUs != null && endTimeUs != null
                ? (endTimeUs - startTimeUs) / 1000.0
                : null,
            'request_size_bytes': reqSize,
            'response_size_bytes': resSize,
            'start_time': startTimeStr,
          });
        }
      }
    }

    final includeRawResponse =
        req.arguments?['includeRawResponse'] as bool? ?? false;
    return serializeDualFormat(
      title: 'Network Diagnostics Report',
      markdownBody: md.toString(),
      structuredData: {
        'total_requests': requestsList.length,
        'requests': formattedRequests,
        if (includeRawResponse) 'raw_response': result,
      },
      format: req.arguments?['format'] as String?,
    );
  }

  /// Handles the start_network_capture tool request.
  Future<CallToolResult> _handleStartNetworkCapture(CallToolRequest req) async {
    if (isCapturingNetwork) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'Already capturing network traffic. Call stop_network_capture first.',
          ),
        ],
        isError: true,
      );
    }

    stderr.writeln('[mcp:network_capture] Starting network capture...');
    isCapturingNetwork = true;
    networkCaptureStartTime = DateTime.now().millisecondsSinceEpoch;
    capturedRequests.clear();

    try {
      await vmService!.streamListen(EventStreams.kExtension);
    } catch (e) {
      stderr.writeln('[mcp:network] Error subscribing to extension stream: $e');
    }

    try {
      await vmService!.callServiceExtension(
        'ext.dart.io.httpEnableTimelineLogging',
        isolateId: isolateId,
        args: {'enabled': 'true'},
      );
    } catch (e) {
      stderr.writeln('[mcp:network] Error enabling HTTP timeline logging: $e');
    }

    networkExtensionSub = vmService!.onExtensionEvent.listen((event) {
      final kind = event.extensionKind;
      final data = event.extensionData?.data;
      if (data == null) return;

      if (kind == 'dart:io.httpClient.request.start') {
        final id = data['id']?.toString() ??
            'req_${DateTime.now().millisecondsSinceEpoch}';
        capturedRequests[id] = {
          'id': id,
          'method': data['method'] ?? 'GET',
          'uri': data['uri'] ?? 'unknown',
          'startTime': DateTime.now().millisecondsSinceEpoch,
          'requestSize': data['contentLength'] ?? 0,
        };
      } else if (kind == 'dart:io.httpClient.request.finish') {
        final id = data['id']?.toString();
        if (id != null && capturedRequests.containsKey(id)) {
          final reqMap = capturedRequests[id]!;
          reqMap['endTime'] = DateTime.now().millisecondsSinceEpoch;
          reqMap['statusCode'] = data['statusCode'];
          reqMap['responseSize'] = data['contentLength'] ?? 0;
          final responseMap = data['response'] as Map?;
          if (responseMap != null) {
            final headers = responseMap['headers'] as Map?;
            reqMap['contentType'] = headers?['content-type'];
          }
        }
      } else if (kind == 'dart:io.httpClient.request.error') {
        final id = data['id']?.toString();
        if (id != null && capturedRequests.containsKey(id)) {
          final reqMap = capturedRequests[id]!;
          reqMap['endTime'] = DateTime.now().millisecondsSinceEpoch;
          reqMap['error'] = data['error']?.toString() ?? 'Unknown error';
        }
      }
    });

    return CallToolResult(
      content: [
        TextContent(
          text:
              'Network capture started. Use the app to trigger API calls, then call `stop_network_capture` to see the results.',
        ),
      ],
    );
  }

  /// Handles the stop_network_capture tool request.
  Future<CallToolResult> _handleStopNetworkCapture(CallToolRequest req) async {
    if (!isCapturingNetwork) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'Not capturing network traffic. Call start_network_capture first.',
          ),
        ],
        isError: true,
      );
    }

    final sortByStr = req.arguments?['sortBy'] as String? ?? 'time';
    final sortBy = NetworkSortBy.fromString(sortByStr);

    stderr.writeln('[mcp:network_capture] Stopping network capture...');
    isCapturingNetwork = false;
    await networkExtensionSub?.cancel();
    networkExtensionSub = null;
    await networkLoggingSub?.cancel();
    networkLoggingSub = null;

    try {
      await vmService!.callServiceExtension(
        'ext.dart.io.httpEnableTimelineLogging',
        isolateId: isolateId,
        args: {'enabled': 'false'},
      );
    } catch (e) {
      stderr.writeln('[mcp:network] Error disabling HTTP timeline logging: $e');
    }

    final durationMs =
        DateTime.now().millisecondsSinceEpoch - networkCaptureStartTime!;
    final allRequests = capturedRequests.values.toList();

    if (allRequests.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'Captured for ${(durationMs / 1000.0).toStringAsFixed(1)}s - no HTTP requests detected.\n\n'
                'This can happen if:\n'
                "- The app didn't make any network calls during capture\n"
                '- HTTP timeline logging is not supported in this Flutter version\n\n'
                'Try making the app load data (e.g. pull to refresh, navigate to a new screen).',
          ),
        ],
      );
    }

    if (sortBy == NetworkSortBy.duration) {
      allRequests.sort((a, b) {
        final durA = a['endTime'] != null
            ? (a['endTime'] as int) - (a['startTime'] as int)
            : 0;
        final durB = b['endTime'] != null
            ? (b['endTime'] as int) - (b['startTime'] as int)
            : 0;
        return durB.compareTo(durA);
      });
    } else if (sortBy == NetworkSortBy.size) {
      allRequests.sort(
        (a, b) => ((b['responseSize'] as int?) ?? 0)
            .compareTo((a['responseSize'] as int?) ?? 0),
      );
    } else {
      allRequests.sort(
        (a, b) => (a['startTime'] as int).compareTo(b['startTime'] as int),
      );
    }

    final completedRequests = allRequests
        .where((r) => r['endTime'] != null && r['error'] == null)
        .toList();
    final failedRequests =
        allRequests.where((r) => r['error'] != null).toList();
    final pendingRequests = allRequests
        .where((r) => r['endTime'] == null && r['error'] == null)
        .toList();

    final totalSize = allRequests.fold<int>(
      0,
      (sum, r) => sum + ((r['responseSize'] as int?) ?? 0),
    );
    final durations = completedRequests
        .map((r) => (r['endTime'] as int) - (r['startTime'] as int))
        .toList();
    final avgDuration = durations.isNotEmpty
        ? durations.reduce((a, b) => a + b) / durations.length
        : 0.0;
    final maxDuration =
        durations.isNotEmpty ? durations.reduce((a, b) => a > b ? a : b) : 0;

    String formatDuration(double ms) {
      if (ms < 1.0) return '<1ms';
      if (ms < 1000.0) return '${ms.round()}ms';
      return '${(ms / 1000.0).toStringAsFixed(2)}s';
    }

    final output = [
      'NETWORK TRAFFIC REPORT',
      '',
      'SUMMARY',
      'Captured for ${(durationMs / 1000.0).toStringAsFixed(1)}s',
      'Total requests: ${allRequests.length}',
      'Completed: ${completedRequests.length} | Failed: ${failedRequests.length} | Pending: ${pendingRequests.length}',
      'Total response size: ${formatBytes(totalSize)}',
      'Average response time: ${formatDuration(avgDuration)}',
      'Slowest request: ${formatDuration(maxDuration.toDouble())}',
      '',
      'REQUESTS',
    ];

    for (final reqMap in allRequests) {
      final durationVal = reqMap['endTime'] != null
          ? ((reqMap['endTime'] as int) - (reqMap['startTime'] as int))
              .toDouble()
          : null;
      final durationStr =
          durationVal != null ? formatDuration(durationVal) : 'pending...';

      final statusSymbol = switch (reqMap) {
        {'error': final err} when err != null => '[ERROR] $err',
        {'statusCode': final int code} => switch (code) {
            >= 400 => '[ERROR] $code',
            >= 300 => '[WARN]  $code',
            _ => '[OK]    $code',
          },
        _ => '[PENDING]',
      };

      final sizeStr = reqMap['responseSize'] != null
          ? formatBytes(reqMap['responseSize'] as int)
          : '-';
      final method = reqMap['method'] as String? ?? 'GET';
      final uri = reqMap['uri'] as String? ?? 'unknown';

      output.add('$statusSymbol $method $durationStr | $sizeStr | $uri');
    }

    final slowRequests = completedRequests
        .where((r) => ((r['endTime'] as int) - (r['startTime'] as int)) > 2000)
        .toList();
    final largeResponses = completedRequests
        .where((r) => ((r['responseSize'] as int?) ?? 0) > 500000)
        .toList();

    if (slowRequests.isNotEmpty ||
        largeResponses.isNotEmpty ||
        failedRequests.isNotEmpty) {
      output.add('');
      output.add('CONCERNS');
      for (final r in slowRequests.take(3)) {
        final dur =
            ((r['endTime'] as int) - (r['startTime'] as int)).toDouble();
        output.add(
          '- SLOW: ${r['method']} ${r['uri']} took ${formatDuration(dur)}',
        );
      }
      for (final r in largeResponses.take(3)) {
        output.add(
          '- LARGE: ${r['method']} ${r['uri']} returned ${formatBytes(r['responseSize'] as int)}',
        );
      }
      for (final r in failedRequests.take(3)) {
        output.add('- ERROR: ${r['method']} ${r['uri']} - ${r['error']}');
      }
    }

    return serializeDualFormat(
      title: 'Network Traffic Report',
      markdownBody: output.join('\n'),
      structuredData: {
        'duration_ms': durationMs,
        'total_requests': allRequests.length,
        'requests': allRequests,
      },
      format: req.arguments?['format'] as String?,
    );
  }
}

/// Sorting strategies for captured network requests.
enum NetworkSortBy {
  /// Sort requests chronologically by start time.
  time('time'),

  /// Sort requests by request execution duration.
  duration('duration'),

  /// Sort requests by response content size.
  size('size');

  /// The raw String identifier of the sort strategy.
  final String value;

  const NetworkSortBy(this.value);

  /// Resolves the sort enum from a nullable raw string, defaulting to [time].
  static NetworkSortBy fromString(String? val) {
    return NetworkSortBy.values.firstWhere(
      (e) => e.value == val,
      orElse: () => NetworkSortBy.time,
    );
  }
}
