part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for advanced HTTP diagnostics: detailed request history
/// with timing, and toggling the dart:io HTTP timeline logging.
extension AdvancedNetworkHandlers on FlutterAgentLensServer {
  /// Fetches the dart:io HTTP profile and surfaces per-request timing
  /// (total duration plus connection/request/response phase breakdown where
  /// available), sorted slowest-first.
  Future<CallToolResult> _handleGetHttpProfile(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 50;

    stderr
        .writeln('[mcp:get_http_profile] Fetching HTTP profile, limit=$limit');

    try {
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
        // Some runtimes return the requests at the top level of json.
        result = response.json != null
            ? Map<String, dynamic>.from(response.json!)
            : <String, dynamic>{};
      }

      final requestsList = result['requests'] as List<dynamic>? ?? [];
      stderr.writeln(
          '[mcp:get_http_profile] Found ${requestsList.length} requests');

      final parsed = <Map<String, dynamic>>[];
      for (final reqObj in requestsList) {
        if (reqObj is! Map) continue;
        final m = Map<String, dynamic>.from(reqObj);

        final id = m['id']?.toString() ?? 'N/A';
        final method = m['method']?.toString() ?? 'N/A';
        final uri = m['uri']?.toString() ?? 'N/A';

        final requestData = m['request'] is Map
            ? Map<String, dynamic>.from(m['request'] as Map)
            : null;
        final responseData = m['response'] is Map
            ? Map<String, dynamic>.from(m['response'] as Map)
            : null;

        final statusCode = responseData?['statusCode']?.toString() ?? 'Pending';

        final startTimeUs = (m['startTime'] as num?)?.toInt();
        final endTimeUs = (m['endTime'] as num?)?.toInt();
        double? durationMs;
        if (startTimeUs != null && endTimeUs != null) {
          durationMs = (endTimeUs - startTimeUs) / 1000.0;
        }

        // Phase timing if the runtime exposes connection/request events.
        final reqStartUs = (requestData?['startTime'] as num?)?.toInt();
        final reqEndUs = (requestData?['endTime'] as num?)?.toInt();
        double? requestPhaseMs;
        if (reqStartUs != null && reqEndUs != null) {
          requestPhaseMs = (reqEndUs - reqStartUs) / 1000.0;
        }
        final resStartUs = (responseData?['startTime'] as num?)?.toInt();
        final resEndUs = (responseData?['endTime'] as num?)?.toInt();
        double? responsePhaseMs;
        if (resStartUs != null && resEndUs != null) {
          responsePhaseMs = (resEndUs - resStartUs) / 1000.0;
        }

        parsed.add({
          'id': id,
          'method': method,
          'uri': uri,
          'statusCode': statusCode,
          'duration_ms': durationMs,
          'request_phase_ms': requestPhaseMs,
          'response_phase_ms': responsePhaseMs,
          'request_size_bytes': requestData?['contentLength'] ?? 0,
          'response_size_bytes': responseData?['contentLength'] ?? 0,
          'start_time_us': startTimeUs,
        });
      }

      // Sort slowest first (completed requests ahead of pending ones).
      parsed.sort((a, b) {
        final da = a['duration_ms'] as double?;
        final db = b['duration_ms'] as double?;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });

      final limited = parsed.take(limit).toList();

      final md = StringBuffer();
      if (limited.isEmpty) {
        md.writeln('No HTTP requests recorded. Enable logging with '
            '`enable_http_logging`, then exercise the app, then re-query.');
      } else {
        md.writeln('Showing ${limited.length} of ${parsed.length} requests '
            '(slowest first):');
        md.writeln();
        md.writeln(
            '| Method | URI | Status | Total | Req Phase | Res Phase | Res Size |');
        md.writeln('| :--- | :--- | :--- | :--- | :--- | :--- | :--- |');
        String ms(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} ms';
        for (final r in limited) {
          final uri = r['uri'] as String;
          final displayUri =
              uri.length > 48 ? '${uri.substring(0, 45)}...' : uri;
          md.writeln('| **${r['method']}** | `$displayUri` '
              '| `${r['statusCode']}` | ${ms(r['duration_ms'] as double?)} '
              '| ${ms(r['request_phase_ms'] as double?)} '
              '| ${ms(r['response_phase_ms'] as double?)} '
              '| ${r['response_size_bytes']} B |');
        }
      }

      return _serializeDualFormat(
        title: '### HTTP Profile (Detailed Timing)',
        markdownBody: md.toString(),
        structuredData: {
          'total_requests': parsed.length,
          'returned_requests': limited.length,
          'requests': limited,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:get_http_profile] ERROR: $e');
      stderr.writeln('[mcp:get_http_profile] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Failed to fetch HTTP profile: $e')],
        isError: true,
      );
    }
  }

  /// Enables dart:io HTTP timeline logging so subsequent requests are captured
  /// by the HTTP profiler.
  Future<CallToolResult> _handleEnableHttpLogging(CallToolRequest req) async {
    return _setHttpLogging(enabled: true);
  }

  /// Disables dart:io HTTP timeline logging.
  Future<CallToolResult> _handleDisableHttpLogging(CallToolRequest req) async {
    return _setHttpLogging(enabled: false);
  }

  Future<CallToolResult> _setHttpLogging({required bool enabled}) async {
    if (_vmService == null || _isolateId == null) return _notConnected();

    final logTag = enabled ? 'enable_http_logging' : 'disable_http_logging';
    stderr.writeln('[mcp:$logTag] Setting HTTP timeline logging to $enabled');

    try {
      await _vmService!.callServiceExtension(
        'ext.dart.io.httpEnableTimelineLogging',
        isolateId: _isolateId,
        args: {'enabled': enabled},
      );

      final verb = enabled ? 'enabled' : 'disabled';
      return CallToolResult(
        content: [
          TextContent(
            text: enabled
                ? 'HTTP timeline logging $verb. New requests will now be '
                    'recorded — exercise the app, then call get_http_profile.'
                : 'HTTP timeline logging $verb.',
          ),
        ],
      );
    } catch (e, st) {
      stderr.writeln('[mcp:$logTag] ERROR: $e');
      stderr.writeln('[mcp:$logTag] STACKTRACE: $st');
      return CallToolResult(
        content: [
          TextContent(
              text: 'Failed to ${enabled ? 'enable' : 'disable'} '
                  'HTTP logging: $e')
        ],
        isError: true,
      );
    }
  }
}
