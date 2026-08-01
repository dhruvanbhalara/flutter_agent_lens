import 'dart:async';

/// Manages and processes real-time network request traffic reports.
final class NetworkWatchManager {
  /// Processes raw network requests in parallel to avoid N+1 RPC query bottlenecks.
  Future<List<Map<String, dynamic>>> processNetworkRequests({
    required List<Map<String, dynamic>> rawRequests,
    required bool includeDetails,
    required Future<Map<String, dynamic>?> Function(String id) fetchDetails,
  }) async {
    if (!includeDetails) {
      return rawRequests.map(_formatBaseRequest).toList();
    }

    final futures = rawRequests.map((reqMap) async {
      final base = _formatBaseRequest(reqMap);
      final id = reqMap['id']?.toString();
      if (id != null && id != 'N/A') {
        final details = await fetchDetails(id);
        if (details != null) {
          base['details'] = details;
        }
      }
      return base;
    });

    return Future.wait(futures);
  }

  Map<String, dynamic> _formatBaseRequest(Map<String, dynamic> reqMap) {
    final startUs = (reqMap['startTime'] as num?)?.toInt();
    final endUs = (reqMap['endTime'] as num?)?.toInt();
    final durationVal =
        (startUs != null && endUs != null) ? (endUs - startUs) / 1000.0 : null;

    final requestData = reqMap['request'] as Map<String, dynamic>?;
    final responseData = reqMap['response'] as Map<String, dynamic>?;

    return {
      'id': reqMap['id']?.toString() ?? 'N/A',
      'method': reqMap['method']?.toString() ?? 'GET',
      'uri': reqMap['uri']?.toString() ?? 'unknown',
      'statusCode': responseData?['statusCode'] ?? 'Pending',
      'duration_ms': durationVal,
      'request_size_bytes':
          (requestData?['contentLength'] as num?)?.toInt() ?? 0,
      'response_size_bytes':
          (responseData?['contentLength'] as num?)?.toInt() ?? 0,
    };
  }
}
