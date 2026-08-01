import 'dart:io';

/// Manages log entry broadcasting to concurrent listeners safely.
final class LogStreamBroadcaster {
  final Set<void Function(String line)> _listeners = {};

  /// Adds a listener for real-time log entries and returns an unsubscribe handle.
  void Function() addListener(void Function(String line) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Broadcasts a formatted line to all active listeners.
  void dispatch(String line) {
    for (final listener in _listeners.toList()) {
      try {
        listener(line);
      } catch (e, st) {
        stderr.writeln('[LogStreamBroadcaster] Listener error: $e\n$st');
      }
    }
  }

  /// Indicates whether any listeners are currently subscribed.
  bool get hasListeners => _listeners.isNotEmpty;
}
