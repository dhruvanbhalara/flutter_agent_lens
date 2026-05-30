part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for reading the Dart HTTP network profile.
extension NetworkHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleGetNetworkProfile(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();

    try {
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
      stderr.writeln(
          '[mcp:network_profile] Found ${requestsList.length} requests');
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
    } catch (e) {
      stderr.writeln('[mcp:network_profile] ERROR: $e');
      return CallToolResult(
        content: [
          TextContent(text: 'Failed to retrieve HTTP network profile: $e')
        ],
        isError: true,
      );
    }
  }
}
