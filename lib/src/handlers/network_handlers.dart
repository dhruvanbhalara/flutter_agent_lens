part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for reading the Dart HTTP network profile.
extension NetworkHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleGetNetworkProfile(CallToolRequest req) async {
    stderr.writeln('[mcp:network_profile] Fetching HTTP profile...');
    final response = await _vmService!.callServiceExtension(
      'ext.dart.io.getHttpProfile',
      isolateId: _isolateId,
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
    final md = StringBuffer('### Network HTTP Profile History\n\n');

    if (requestsList.isEmpty) {
      md.writeln('No network requests recorded.');
    } else {
      md.writeln(
          '| ID | Method | URI | Status | Duration | Req Size | Res Size | Start Time |');
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
          String durationStr = 'Pending';
          if (startTimeUs != null && endTimeUs != null) {
            final durationMs = (endTimeUs - startTimeUs) / 1000.0;
            durationStr = '${durationMs.toStringAsFixed(1)} ms';
          }

          String startTimeStr = 'Unknown';
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
              '| `$id` | **$method** | `$displayUri` | `$statusCode` | $durationStr | $reqSize B | $resSize B | $startTimeStr |');

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

    return _serializeDualFormat(
      title: '### Network Diagnostics Report',
      markdownBody: md.toString(),
      structuredData: {
        'total_requests': requestsList.length,
        'requests': formattedRequests,
        'raw_response': result,
      },
    );
  }

  Future<CallToolResult> _handleStartNetworkCapture(CallToolRequest req) async {
    if (_isCapturingNetwork) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Already capturing network traffic. Call stop_network_capture first.')
        ],
        isError: true,
      );
    }

    stderr.writeln('[mcp:network_capture] Starting network capture...');
    _isCapturingNetwork = true;
    _networkCaptureStartTime = DateTime.now().millisecondsSinceEpoch;
    _capturedRequests.clear();

    try {
      await _vmService!.streamListen(EventStreams.kExtension);
    } catch (_) {}

    // Enable HTTP timeline logging
    try {
      await _vmService!.callServiceExtension(
        'ext.dart.io.httpEnableTimelineLogging',
        isolateId: _isolateId!,
        args: {'enabled': 'true'},
      );
    } catch (_) {}

    _networkExtensionSub = _vmService!.onExtensionEvent.listen((Event event) {
      final kind = event.extensionKind;
      final data = event.extensionData?.data;
      if (data == null) return;

      if (kind == 'dart:io.httpClient.request.start') {
        final id = data['id']?.toString() ??
            'req_${DateTime.now().millisecondsSinceEpoch}';
        _capturedRequests[id] = {
          'id': id,
          'method': data['method'] ?? 'GET',
          'uri': data['uri'] ?? 'unknown',
          'startTime': DateTime.now().millisecondsSinceEpoch,
          'requestSize': data['contentLength'] ?? 0,
        };
      } else if (kind == 'dart:io.httpClient.request.finish') {
        final id = data['id']?.toString();
        if (id != null && _capturedRequests.containsKey(id)) {
          final reqMap = _capturedRequests[id]!;
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
        if (id != null && _capturedRequests.containsKey(id)) {
          final reqMap = _capturedRequests[id]!;
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
        )
      ],
    );
  }

  Future<CallToolResult> _handleStopNetworkCapture(CallToolRequest req) async {
    if (!_isCapturingNetwork) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Not capturing network traffic. Call start_network_capture first.')
        ],
        isError: true,
      );
    }

    final sortBy = req.arguments?['sortBy'] as String? ?? 'time';

    stderr.writeln('[mcp:network_capture] Stopping network capture...');
    _isCapturingNetwork = false;
    await _networkExtensionSub?.cancel();
    _networkExtensionSub = null;
    await _networkLoggingSub?.cancel();
    _networkLoggingSub = null;

    // Disable HTTP timeline logging
    try {
      await _vmService!.callServiceExtension(
        'ext.dart.io.httpEnableTimelineLogging',
        isolateId: _isolateId!,
        args: {'enabled': 'false'},
      );
    } catch (_) {}

    final durationMs =
        DateTime.now().millisecondsSinceEpoch - _networkCaptureStartTime!;
    final allRequests = _capturedRequests.values.toList();

    if (allRequests.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'Captured for ${(durationMs / 1000.0).toStringAsFixed(1)}s — no HTTP requests detected.\n\n'
                'This can happen if:\n'
                '• The app didn\'t make any network calls during capture\n'
                '• HTTP timeline logging is not supported in this Flutter version\n\n'
                'Try making the app load data (e.g. pull to refresh, navigate to a new screen).',
          ),
        ],
      );
    }

    // Sorting
    if (sortBy == 'duration') {
      allRequests.sort((a, b) {
        final durA = a['endTime'] != null
            ? (a['endTime'] as int) - (a['startTime'] as int)
            : 0;
        final durB = b['endTime'] != null
            ? (b['endTime'] as int) - (b['startTime'] as int)
            : 0;
        return durB.compareTo(durA);
      });
    } else if (sortBy == 'size') {
      allRequests.sort((a, b) => ((b['responseSize'] as int?) ?? 0)
          .compareTo((a['responseSize'] as int?) ?? 0));
    } else {
      // time sorting
      allRequests.sort(
          (a, b) => (a['startTime'] as int).compareTo(b['startTime'] as int));
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
        0, (sum, r) => sum + ((r['responseSize'] as int?) ?? 0));
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

    String formatSize(int bytes) {
      if (bytes == 0) return '0 B';
      final k = 1024;
      final sizes = ['B', 'KB', 'MB'];
      var i = 0;
      var val = bytes.toDouble();
      while (val >= k && i < sizes.length - 1) {
        val /= k;
        i++;
      }
      return '${val.toStringAsFixed(1)} ${sizes[i]}';
    }

    final output = [
      '═══════════════════════════════════════════════════════════',
      '  NETWORK TRAFFIC REPORT',
      '═══════════════════════════════════════════════════════════',
      '',
      '  SUMMARY',
      '───────────────────────────────────────────────────────────',
      'Captured for ${(durationMs / 1000.0).toStringAsFixed(1)}s',
      'Total requests: ${allRequests.length}',
      'Completed: ${completedRequests.length} | Failed: ${failedRequests.length} | Pending: ${pendingRequests.length}',
      'Total response size: ${formatSize(totalSize)}',
      'Average response time: ${formatDuration(avgDuration)}',
      'Slowest request: ${formatDuration(maxDuration.toDouble())}',
      '',
      '  REQUESTS',
      '───────────────────────────────────────────────────────────',
    ];

    for (final reqMap in allRequests) {
      final durationVal = reqMap['endTime'] != null
          ? ((reqMap['endTime'] as int) - (reqMap['startTime'] as int))
              .toDouble()
          : null;
      final durationStr =
          durationVal != null ? formatDuration(durationVal) : 'pending...';

      String statusSymbol;
      if (reqMap['error'] != null) {
        statusSymbol = '[ERROR] ${reqMap['error']}';
      } else if (reqMap['statusCode'] != null) {
        final code = reqMap['statusCode'] as int;
        statusSymbol = code >= 400
            ? '[ERROR] $code'
            : code >= 300
                ? '[WARN]  $code'
                : '[OK]    $code';
      } else {
        statusSymbol = '[PENDING]';
      }

      final sizeStr = reqMap['responseSize'] != null
          ? formatSize(reqMap['responseSize'] as int)
          : '-';
      final method = (reqMap['method'] as String? ?? 'GET').padRight(6);
      final uri = reqMap['uri'] as String? ?? 'unknown';

      output.add(
          '$statusSymbol $method ${durationStr.padLeft(8)} | ${sizeStr.padLeft(8)} | $uri');
    }

    // Potential concerns recommendations
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
      output.add('  CONCERNS');
      output.add('───────────────────────────────────────────────────────────');
      for (final r in slowRequests.take(3)) {
        final dur =
            ((r['endTime'] as int) - (r['startTime'] as int)).toDouble();
        output.add(
            '• SLOW: ${r['method']} ${r['uri']} took ${formatDuration(dur)}');
      }
      for (final r in largeResponses.take(3)) {
        output.add(
            '• LARGE: ${r['method']} ${r['uri']} returned ${formatSize(r['responseSize'] as int)}');
      }
      for (final r in failedRequests.take(3)) {
        output.add('• ERROR: ${r['method']} ${r['uri']} — ${r['error']}');
      }
    }

    return _serializeDualFormat(
      title: '### Network Traffic Report',
      markdownBody: output.join('\n'),
      structuredData: {
        'duration_ms': durationMs,
        'total_requests': allRequests.length,
        'requests': allRequests,
      },
    );
  }
}
