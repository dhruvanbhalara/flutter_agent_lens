import 'dart:async';
import 'package:vm_service/vm_service.dart';

/// Abstract interface for Dart VM Service RPC operations, enabling Dependency Inversion (DIP).
abstract interface class IVmServiceClient {
  /// Active VM Service instance, if connected.
  VmService? get vmService;

  /// Active VM Service URI, if connected.
  String? get vmServiceUri;

  /// Active main isolate ID.
  String? get isolateId;

  /// Workspace root directory path.
  String? get workspaceRoot;

  /// Refreshes the active isolate ID from the running Dart VM.
  Future<bool> refreshIsolateId();

  /// Gets library ID for expression evaluation.
  Future<String> getEvaluationLibraryId();

  /// Closes active connections and cleans up handles.
  FutureOr<void> cleanupStreams();
}
