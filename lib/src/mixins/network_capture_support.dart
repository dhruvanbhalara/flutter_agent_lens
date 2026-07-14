import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/enums/network_sort_by.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';

/// Support mixin providing tools for capturing and analyzing HTTP traffic details.
base mixin NetworkCaptureSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Whether the network capture session is statefully active.
  bool isCapturingNetwork = false;

  /// Timestamp in milliseconds when the network capture session was started.
  int? networkCaptureStartTime;

  /// Set of request IDs that were already present when network capture started.
  final Set<String> _initialRequestIds = {};

  /// Registers network capture tools.
  void registerNetworkTools() {
    registerTool(
      Tool(
        name: McpTool.network.name,
        description: 'Manage HTTP network capture. '
            'Actions: start (begin capture), stop (end and get report), '
            'get_profile (read HTTP request history).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description: 'Action to perform: start, stop, get_profile.',
            ),
            'sortBy': StringSchema(
              description: 'Sort by: time, duration, size (for stop action).',
            ),
            'includeRawResponse': BooleanSchema(
              description:
                  'Whether to include the raw JSON-RPC response in structured data.',
            ),
            'limit': limitSchema(defaultValue: 30),
          },
          required: ['action'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
        ),
      ),
      _handleNetwork,
    );
  }

  Map<String, dynamic> _sanitizeRequest(Map<dynamic, dynamic> r) {
    final sanitized = Map<String, dynamic>.from(r);
    if (sanitized['request'] is Map) {
      sanitized['request'] =
          Map<String, dynamic>.from(sanitized['request'] as Map);
    }
    if (sanitized['response'] is Map) {
      sanitized['response'] =
          Map<String, dynamic>.from(sanitized['response'] as Map);
    }
    return sanitized;
  }

  Future<List<Map<String, dynamic>>> _getHttpRequests() async {
    final vm = vmService;
    if (vm == null || isolateId == null) return const [];
    try {
      final response = await vm.callServiceExtension(
        'ext.dart.io.getHttpProfile',
        isolateId: isolateId,
      );
      final jsonMap = response.json ?? {};
      final rawResult = jsonMap['result'];
      Map<String, dynamic> result;
      if (rawResult is String) {
        result = jsonDecode(rawResult) as Map<String, dynamic>;
      } else if (rawResult is Map) {
        result = Map<String, dynamic>.from(rawResult);
      } else if (jsonMap.containsKey('requests')) {
        result = jsonMap;
      } else {
        result = {};
      }
      final rawRequests = result['requests'] as List<dynamic>? ?? [];
      final allRequests = <Map<String, dynamic>>[];
      for (final r in rawRequests) {
        if (r is Map) {
          allRequests.add(_sanitizeRequest(r));
        }
      }
      return allRequests;
    } catch (e) {
      stderr.writeln('[mcp:network] Error fetching HTTP requests: $e');
      return const [];
    }
  }

  /// Disposes active stream subscriptions and clears stateful captured requests.
  Future<void> cleanupNetworkCapture() async {
    isCapturingNetwork = false;
    networkCaptureStartTime = null;
    _initialRequestIds.clear();
    if (vmService != null && isolateId != null) {
      try {
        await vmService!.callServiceExtension(
          'ext.dart.io.httpEnableTimelineLogging',
          isolateId: isolateId!,
          args: {'enabled': 'false'},
        );
      } catch (_) {}
    }
  }

  /// Helper to check if http profiling is supported.
  Future<bool> _checkHttpProfileSupport() async {
    final vm = vmService;
    if (vm == null || isolateId == null) return false;
    try {
      final isolate = await vm.getIsolate(isolateId!);
      final rpcs = isolate.extensionRPCs ?? [];
      return rpcs.contains('ext.dart.io.getHttpProfile');
    } catch (e) {
      stderr.writeln('[mcp:network] Warning checking HTTP profile support: $e');
      return true; // Fallback to true, let the actual call fail if unsupported
    }
  }

  CallToolResult _getUnsupportedError() {
    return CallToolResult(
      content: [
        TextContent(
          text:
              'Network profiling via the Dart VM Service is not supported on this platform/runtime (e.g., Flutter Web/Wasm).\n\n'
              "Web/Wasm applications execute network calls using the browser's native APIs (fetch/XHR). "
              "Please use your browser's Developer Tools (F12 -> Network tab) to inspect API calls.",
        )
      ],
      isError: true,
    );
  }

  /// Handles the get_network_profile tool request.
  Future<CallToolResult> _handleGetNetworkProfile(CallToolRequest req) async {
    stderr.writeln('[mcp:network_profile] Fetching HTTP profile...');
    if (vmService == null) return notConnected();

    if (!await _checkHttpProfileSupport()) {
      return _getUnsupportedError();
    }

    final limit = (req.arg<num>('limit'))?.toInt() ?? 30;
    var allFetched = await _getHttpRequests();
    // Return only the most recent `limit` requests
    if (allFetched.length > limit) {
      allFetched = allFetched.sublist(allFetched.length - limit);
    }
    stderr.writeln('[mcp:network_profile] Found ${allFetched.length} requests');
    final formattedRequests = <Map<String, dynamic>>[];
    final md = StringBuffer('Network HTTP Profile History\n\n');

    if (allFetched.isEmpty) {
      md.writeln('No network requests recorded.');
    } else {
      md.writeln(
          '| ID | Method | URI | Status | Duration | Req Size | Res Size | Start Time |');
      md.writeln('| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |');

      for (final reqMap in allFetched) {
        final id = reqMap['id']?.toString() ?? 'N/A';
        final method = reqMap['method']?.toString() ?? 'N/A';
        final uri = reqMap['uri']?.toString() ?? 'N/A';

        final requestData = reqMap['request'] as Map<String, dynamic>?;
        final responseData = reqMap['response'] as Map<String, dynamic>?;

        final statusCode = responseData?['statusCode']?.toString() ?? 'Pending';

        final startTimeUs = reqMap['startTime'] as int?;
        final endTimeUs = reqMap['endTime'] as int?;
        String durationStr = 'Pending';
        if (startTimeUs != null && endTimeUs != null) {
          final durationMs = (endTimeUs - startTimeUs) / 1000.0;
          durationStr = '${durationMs.toStringAsFixed(1)} ms';
        }

        String startTimeStr = 'Unknown';
        if (startTimeUs != null) {
          final dt = DateTime.fromMicrosecondsSinceEpoch(startTimeUs);
          startTimeStr = dt.toIso8601String().split('T').last.substring(0, 12);
        }

        final reqSize = requestData?['contentLength'] ?? 0;
        final resSize = responseData?['contentLength'] ?? 0;
        final displayUri = uri.length > 50 ? '${uri.substring(0, 47)}...' : uri;

        md.writeln(
            '| `$id` | $method | `$displayUri` | `$statusCode` | $durationStr | $reqSize B | $resSize B | $startTimeStr |');

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

    final includeRawResponse = req.arg<bool>('includeRawResponse') ?? false;
    return serializeDualFormat(
      title: 'Network Diagnostics Report',
      markdownBody: md.toString(),
      structuredData: {
        'total_requests': allFetched.length,
        'requests': formattedRequests,
        if (includeRawResponse) 'raw_response': allFetched,
      },
    );
  }

  /// Handles the start_network_capture tool request.
  Future<CallToolResult> _handleStartNetworkCapture(CallToolRequest req) async {
    if (isCapturingNetwork) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Already capturing network traffic. Call the `network` tool with action: `stop` first.')
        ],
        isError: true,
      );
    }

    if (!await _checkHttpProfileSupport()) {
      return _getUnsupportedError();
    }

    stderr.writeln('[mcp:network_capture] Starting network capture...');
    isCapturingNetwork = true;
    networkCaptureStartTime = DateTime.now().millisecondsSinceEpoch;
    _initialRequestIds.clear();

    try {
      await vmService!.callServiceExtension(
        'ext.dart.io.httpEnableTimelineLogging',
        isolateId: isolateId!,
        args: {'enabled': 'true'},
      );
    } catch (e) {
      stderr.writeln('[mcp:network] Error enabling HTTP timeline logging: $e');
    }

    // Capture the snapshot of request IDs present at start
    final currentRequests = await _getHttpRequests();
    for (final r in currentRequests) {
      final id = r['id']?.toString();
      if (id != null) {
        _initialRequestIds.add(id);
      }
    }

    return CallToolResult(
      content: [
        TextContent(
          text:
              'Network capture started. Use the app to trigger API calls, then call the `network` tool with action: `stop` to see the results.',
        )
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
                  'Not capturing network traffic. Call the `network` tool with action: `start` first.')
        ],
        isError: true,
      );
    }

    if (!await _checkHttpProfileSupport()) {
      return _getUnsupportedError();
    }

    final sortByStr = req.arg<String>('sortBy') ?? 'time';
    final sortBy = NetworkSortBy.fromString(sortByStr);

    stderr.writeln('[mcp:network_capture] Stopping network capture...');
    isCapturingNetwork = false;

    final start =
        networkCaptureStartTime ?? DateTime.now().millisecondsSinceEpoch;
    final durationMs = DateTime.now().millisecondsSinceEpoch - start;

    // Fetch the new profile and filter out requests present at start
    final currentRequests = await _getHttpRequests();
    final allRequests = <Map<String, dynamic>>[];
    for (final r in currentRequests) {
      final id = r['id']?.toString();
      if (id != null && !_initialRequestIds.contains(id)) {
        allRequests.add(r);
      }
    }
    _initialRequestIds.clear();

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

    // Sort requests
    if (sortBy == NetworkSortBy.duration) {
      allRequests.sort((a, b) {
        final startA = a['startTime'] as int?;
        final endA = a['endTime'] as int?;
        final startB = b['startTime'] as int?;
        final endB = b['endTime'] as int?;
        final durA = (startA != null && endA != null) ? (endA - startA) : 0;
        final durB = (startB != null && endB != null) ? (endB - startB) : 0;
        return durB.compareTo(durA);
      });
    } else if (sortBy == NetworkSortBy.size) {
      allRequests.sort((a, b) {
        final resSizeA = (a['response']
                as Map<String, dynamic>?)?['contentLength'] as int? ??
            0;
        final resSizeB = (b['response']
                as Map<String, dynamic>?)?['contentLength'] as int? ??
            0;
        return resSizeB.compareTo(resSizeA);
      });
    } else {
      allRequests.sort((a, b) {
        final startA = a['startTime'] as int? ?? 0;
        final startB = b['startTime'] as int? ?? 0;
        return startA.compareTo(startB);
      });
    }

    final completedRequests = allRequests.where((r) {
      final responseData = r['response'] as Map<String, dynamic>?;
      return responseData != null && r['endTime'] != null;
    }).toList();

    final failedRequests = allRequests.where((r) {
      final error = r['error']?.toString();
      final responseData = r['response'] as Map<String, dynamic>?;
      final statusCode = responseData?['statusCode'] as int?;
      return error != null || (statusCode != null && statusCode >= 400);
    }).toList();

    final pendingRequests = allRequests.where((r) {
      final responseData = r['response'] as Map<String, dynamic>?;
      return r['endTime'] == null && r['error'] == null && responseData == null;
    }).toList();

    final totalSize = allRequests.fold<int>(0, (sum, r) {
      final responseData = r['response'] as Map<String, dynamic>?;
      return sum + ((responseData?['contentLength'] as int?) ?? 0);
    });

    final durations = completedRequests.map((r) {
      final startUs = r['startTime'] as int? ?? 0;
      final endUs = r['endTime'] as int? ?? 0;
      return (endUs - startUs) / 1000.0;
    }).toList();

    final avgDuration = durations.isNotEmpty
        ? durations.reduce((a, b) => a + b) / durations.length
        : 0.0;
    final maxDuration =
        durations.isNotEmpty ? durations.reduce((a, b) => a > b ? a : b) : 0.0;

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
      'Slowest request: ${formatDuration(maxDuration)}',
      '',
      'REQUESTS',
    ];

    final formattedRequests = <Map<String, dynamic>>[];

    for (final reqMap in allRequests) {
      final id = reqMap['id']?.toString() ?? 'N/A';
      final method = reqMap['method']?.toString() ?? 'GET';
      final uri = reqMap['uri']?.toString() ?? 'unknown';
      final requestData = reqMap['request'] as Map<String, dynamic>?;
      final responseData = reqMap['response'] as Map<String, dynamic>?;

      final startUs = reqMap['startTime'] as int?;
      final endUs = reqMap['endTime'] as int?;
      final durationVal = (startUs != null && endUs != null)
          ? (endUs - startUs) / 1000.0
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

      final reqSize = (requestData?['contentLength'] as int?) ?? 0;
      final resSize = (responseData?['contentLength'] as int?) ?? 0;
      final displayUri = uri.length > 50 ? '${uri.substring(0, 47)}...' : uri;

      output.add(
          '$statusSymbol $method $durationStr | ${formatBytes(resSize)} | $displayUri');

      formattedRequests.add({
        'id': id,
        'method': method,
        'uri': uri,
        'statusCode': responseData?['statusCode'] ?? 'Pending',
        'duration_ms': durationVal,
        'request_size_bytes': reqSize,
        'response_size_bytes': resSize,
      });
    }

    final slowRequests = completedRequests.where((r) {
      final startUs = r['startTime'] as int? ?? 0;
      final endUs = r['endTime'] as int? ?? 0;
      return (endUs - startUs) > 2000000;
    }).toList();

    final largeResponses = completedRequests.where((r) {
      final responseData = r['response'] as Map<String, dynamic>?;
      final len = responseData?['contentLength'] as int? ?? 0;
      return len > 500000;
    }).toList();

    if (slowRequests.isNotEmpty ||
        largeResponses.isNotEmpty ||
        failedRequests.isNotEmpty) {
      output.add('');
      output.add('CONCERNS');
      for (final r in slowRequests.take(3)) {
        final startUs = r['startTime'] as int? ?? 0;
        final endUs = r['endTime'] as int? ?? 0;
        final dur = (endUs - startUs) / 1000.0;
        output.add(
            '- SLOW: ${r['method']} ${r['uri']} took ${formatDuration(dur)}');
      }
      for (final r in largeResponses.take(3)) {
        final responseData = r['response'] as Map<String, dynamic>?;
        final len = responseData?['contentLength'] as int? ?? 0;
        output.add(
            '- LARGE: ${r['method']} ${r['uri']} returned ${formatBytes(len)}');
      }
      for (final r in failedRequests.take(3)) {
        final error = r['error']?.toString();
        final responseData = r['response'] as Map<String, dynamic>?;
        final statusCode = responseData?['statusCode']?.toString();
        output.add(
            '- ERROR: ${r['method']} ${r['uri']} - ${error ?? "Status Code $statusCode"}');
      }
    }

    final includeRawResponse = req.arg<bool>('includeRawResponse') ?? false;
    return serializeDualFormat(
      title: 'Network Traffic Report',
      markdownBody: output.join('\n'),
      structuredData: {
        'duration_ms': durationMs,
        'total_requests': allRequests.length,
        'requests': formattedRequests,
        if (includeRawResponse) 'raw_response': allRequests,
      },
    );
  }

  /// Handles the network composite tool request.
  Future<CallToolResult> _handleNetwork(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    return switch (action) {
      'start' => _handleStartNetworkCapture(req),
      'stop' => _handleStopNetworkCapture(req),
      'get_profile' => _handleGetNetworkProfile(req),
      _ => CallToolResult(
          content: [TextContent(text: 'Unknown network action: $action')],
          isError: true,
        ),
    };
  }
}
