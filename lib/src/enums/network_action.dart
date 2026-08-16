import 'package:flutter_agent_lens/src/enums/action_enum.dart';

/// Actions supported by the network tool.
enum NetworkAction implements ActionEnum {
  /// Start capturing HTTP network requests.
  start('start'),

  /// Stop network capture and return summary.
  stop('stop'),

  /// Get recorded HTTP request profile.
  getProfile('getProfile'),

  /// Watch network traffic for a duration window.
  watch('watch'),

  /// Get detailed headers, body, and timing for a request.
  getRequestDetails('getRequestDetails');

  const NetworkAction(this.value);

  @override
  final String value;

  static final Map<String, NetworkAction> _lookup = {
    for (final e in NetworkAction.values) e.value.toLowerCase(): e,
  };

  /// Resolves the action from a raw string.
  /// Returns `null` if the action is null or unsupported.
  static NetworkAction? fromString(String? val) {
    if (val == null) return null;
    return _lookup[val.toLowerCase()];
  }
}
