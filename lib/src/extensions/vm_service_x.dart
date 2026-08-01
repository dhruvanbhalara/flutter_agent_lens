import 'dart:io';

import 'package:vm_service/vm_service.dart';

/// Extension on [VmService] to provide standard extension toggling and safe evaluation.
extension VmServiceX on VmService {
  /// Safely toggles a Flutter service extension (`ext.flutter.<extensionSuffix>`).
  ///
  /// Passes `{'enabled': 'true'}` or `{'enabled': 'false'}` in accordance with
  /// Flutter DevTools conventions.
  Future<Response> toggleFlutterExtension(
    String extensionSuffix, {
    required bool enabled,
    String? isolateId,
  }) async {
    final fullExtensionName = 'ext.flutter.$extensionSuffix';
    return callServiceExtension(
      fullExtensionName,
      isolateId: isolateId,
      args: {'enabled': enabled ? 'true' : 'false'},
    );
  }

  /// Safely evaluates [expression] in [libraryId] for [isolateId].
  ///
  /// Returns `null` if the evaluation fails due to a sentinel exception or RPC error
  /// (e.g. object collected during evaluation).
  Future<Response?> evalSafe(
    String isolateId,
    String libraryId,
    String expression,
  ) async {
    try {
      return await evaluate(isolateId, libraryId, expression);
    } catch (e, st) {
      if (e is SentinelException ||
          (e is RPCError &&
              (e.code == 106 ||
                  e.message.contains('collected') ||
                  e.message.toLowerCase().contains('sentinel')))) {
        stderr.writeln(
          '[VmServiceX.evalSafe] Caught sentinel/collected error during evaluate("$expression"): $e',
        );
        return null;
      }
      stderr.writeln(
        '[VmServiceX.evalSafe] Evaluate failed ("$expression"): $e\n$st',
      );
      return null;
    }
  }
}
