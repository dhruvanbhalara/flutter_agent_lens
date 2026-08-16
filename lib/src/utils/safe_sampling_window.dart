import 'dart:async';

import 'package:vm_service/vm_service.dart';

/// Discrete outcome of a time-bounded VM sampling operation.
typedef SamplingResult = ({
  bool completed,
  Duration elapsed,
  String? interruptReason,
});

/// Typed sampling interruption causes.
extension type const InterruptionReason(String value) {
  /// VM Service connection dropped before sampling completed.
  static const InterruptionReason vmDisconnected =
      InterruptionReason('vm_service_disconnected');
}

/// Appends a GitHub-flavored markdown alert to [buffer]
/// if sampling was prematurely interrupted.
void writeSamplingWarningIfInterrupted(
  SamplingResult result,
  StringSink buffer, {
  required int requestedSeconds,
  required String dataName,
}) {
  if (!result.completed) {
    final elapsedSec = result.elapsed.inSeconds;
    final reason = result.interruptReason ?? 'disconnected';
    buffer.writeln('> [!WARNING]');
    buffer.writeln(
      '> Sampling interrupted after ${elapsedSec}s (requested ${requestedSeconds}s). '
      'Reason: $reason. Partial $dataName follow.\n',
    );
  }
}

/// Waits for [duration], terminating early if [vmService] closes or disconnects.
///
/// Converts the completion listener into a stream subscription and cancels it
/// when the window resolves to avoid holding references to long-lived objects.
Future<SamplingResult> safeSamplingWindow({
  required VmService? vmService,
  required Duration duration,
}) async {
  if (vmService == null) {
    await Future<void>.delayed(duration);
    return (completed: true, elapsed: duration, interruptReason: null);
  }

  final stopwatch = Stopwatch()..start();
  final completer = Completer<SamplingResult>();

  final timer = Timer(duration, () {
    if (!completer.isCompleted) {
      stopwatch.stop();
      completer.complete(
        (completed: true, elapsed: stopwatch.elapsed, interruptReason: null),
      );
    }
  });

  void handlePrematureDisconnection() {
    if (!completer.isCompleted) {
      timer.cancel();
      stopwatch.stop();
      completer.complete((
        completed: false,
        elapsed: stopwatch.elapsed,
        interruptReason: InterruptionReason.vmDisconnected.value,
      ));
    }
  }

  final disconnectSub = vmService.onDone.asStream().listen(
        (_) => handlePrematureDisconnection(),
        onError: (_) => handlePrematureDisconnection(),
      );

  return completer.future.whenComplete(() {
    timer.cancel();
    unawaited(disconnectSub.cancel());
  });
}
