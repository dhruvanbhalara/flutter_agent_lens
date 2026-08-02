import 'dart:async';

import 'package:vm_service/vm_service.dart';

/// Result of a sampling window that may have been interrupted by VM Service disconnect.
final class SamplingResult {
  /// Whether the full duration completed without interruption.
  final bool completed;

  /// Actual elapsed duration before completion or interruption.
  final Duration elapsed;

  /// Reason for interruption if [completed] is `false`.
  final String? interruptReason;

  /// Creates a new [SamplingResult] instance.
  const SamplingResult({
    required this.completed,
    required this.elapsed,
    this.interruptReason,
  });
}

/// Extension on [SamplingResult] for standardized output warning formatting.
extension SamplingResultX on SamplingResult {
  /// Appends a standardized GitHub alert warning to [buffer] if sampling was interrupted.
  void writeWarningIfInterrupted(
    StringSink buffer, {
    required int requestedSeconds,
    required String dataName,
  }) {
    if (!completed) {
      final elapsedSec = elapsed.inSeconds;
      final reason = interruptReason ?? 'disconnected';
      buffer.writeln('> [!WARNING]');
      buffer.writeln(
        '> Sampling interrupted after ${elapsedSec}s (requested ${requestedSeconds}s). Reason: $reason. Partial $dataName follow.\n',
      );
    }
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
    return SamplingResult(
      completed: true,
      elapsed: duration,
    );
  }

  final stopwatch = Stopwatch()..start();
  final completer = Completer<SamplingResult>();

  final timer = Timer(duration, () {
    if (!completer.isCompleted) {
      stopwatch.stop();
      completer.complete(SamplingResult(
        completed: true,
        elapsed: stopwatch.elapsed,
      ));
    }
  });

  unawaited(vmService.onDone.then((_) {
    if (!completer.isCompleted) {
      timer.cancel();
      stopwatch.stop();
      completer.complete(SamplingResult(
        completed: false,
        elapsed: stopwatch.elapsed,
        interruptReason: 'vm_service_disconnected',
      ));
    }
  }).catchError((_) {
    if (!completer.isCompleted) {
      timer.cancel();
      stopwatch.stop();
      completer.complete(SamplingResult(
        completed: false,
        elapsed: stopwatch.elapsed,
        interruptReason: 'vm_service_disconnected',
      ));
    }
  }));

  return completer.future;
}
