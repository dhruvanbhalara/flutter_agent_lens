import 'dart:async';
import 'dart:io';

/// Manages log entry broadcasting to concurrent listeners safely.
final class LogStreamBroadcaster {
  final StreamController<String> _controller =
      StreamController<String>.broadcast(sync: true);

  /// Adds a listener for real-time log entries and returns an unsubscribe handle.
  void Function() addListener(void Function(String line) listener) {
    final sub = _controller.stream.listen((line) {
      try {
        listener(line);
      } catch (e, st) {
        stderr.writeln('[LogStreamBroadcaster] Listener error: $e\n$st');
      }
    });
    return sub.cancel;
  }

  /// Broadcasts a formatted line to all active listeners.
  void dispatch(String line) => _controller.add(line);

  /// Indicates whether any listeners are currently subscribed.
  bool get hasListeners => _controller.hasListener;
}
