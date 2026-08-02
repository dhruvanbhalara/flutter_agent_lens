import 'dart:async';

import 'package:vm_service/vm_service.dart';

/// Result of a sampling window that may have been interrupted by VM Service disconnect.
typedef SamplingResult = ({
  bool completed,
  Duration elapsed,
  String? interruptReason,
});

/// Appends a standardized GitHub alert warning to [buffer] if sampling was interrupted.
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
      '> Sampling interrupted after ${elapsedSec}s (requested ${requestedSeconds}s). Reason: $reason. Partial $dataName follow.\n',
    );
  }
}

/// Waits for [duration] but terminates early if [vmService] closes or disconnects.
///
/// If [vmService] is `null`, waits for [duration] and returns a completed [SamplingResult].
/// Returns a [SamplingResult] containing completion status and actual elapsed time.
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

  void completeDisconnected() {
    if (!completer.isCompleted) {
      timer.cancel();
      stopwatch.stop();
      completer.complete((
        completed: false,
        elapsed: stopwatch.elapsed,
        interruptReason: 'vm_service_disconnected',
      ));
    }
  }

  unawaited(
    vmService.onDone.then(
      (_) => completeDisconnected(),
      onError: (_) => completeDisconnected(),
    ),
  );

  return completer.future;
}
