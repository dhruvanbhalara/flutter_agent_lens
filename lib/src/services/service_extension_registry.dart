import 'dart:async';
import 'dart:io';

import 'package:vm_service/vm_service.dart';

/// Tracks active VM Service extension RPCs and provides safe, capability-checked helpers.
class ServiceExtensionRegistry {
  final Set<String> _activeRPCs = {};
  StreamSubscription<Event>? _streamSub;

  /// Set of currently registered extension RPC strings (read-only).
  Set<String> get activeRPCs => Set.unmodifiable(_activeRPCs);

  /// Initializes the registry from the main isolate and subscribes to runtime extension events.
  Future<void> initialize(Isolate isolate, VmService vmService) async {
    _activeRPCs.clear();
    final initialRPCs = isolate.extensionRPCs ?? [];
    _activeRPCs.addAll(initialRPCs);

    try {
      await _streamSub?.cancel();
      _streamSub = vmService.onIsolateEvent.listen((event) {
        if (event.kind == EventKind.kServiceExtensionAdded &&
            event.extensionRPC != null) {
          _activeRPCs.add(event.extensionRPC!);
          stderr.writeln(
              '[ServiceExtensionRegistry] Added extension: ${event.extensionRPC}');
        }
      });
    } catch (e) {
      stderr.writeln(
          '[ServiceExtensionRegistry] Warning listening to isolate stream: $e');
    }
  }

  /// Checks if [extensionRPC] is registered on the active target.
  bool isSupported(String extensionRPC) => _activeRPCs.contains(extensionRPC);

  /// Queries target display refresh rate via `ext.flutter.getDisplayRefreshRate`.
  ///
  /// Defaults gracefully to [defaultFps] (60.0) if extension is unavailable.
  Future<double> getDisplayRefreshRate({
    required VmService? vmService,
    required String? isolateId,
    double defaultFps = 60.0,
  }) async {
    const extensionName = 'ext.flutter.getDisplayRefreshRate';
    if (vmService == null || isolateId == null || !isSupported(extensionName)) {
      return defaultFps;
    }
    try {
      final response = await vmService.callServiceExtension(
        extensionName,
        isolateId: isolateId,
      );
      return (response.json?['fps'] as num?)?.toDouble() ?? defaultFps;
    } catch (e) {
      stderr.writeln(
          '[ServiceExtensionRegistry] Error querying display refresh rate: $e');
      return defaultFps;
    }
  }

  /// Queries Skia estimate raster cache memory via `ext.ui.window.getSkiaEstimateRasterCacheMemory`.
  ///
  /// Returns `null` if running under Impeller or if extension is unavailable.
  Future<int?> getRasterCacheMemory({
    required VmService? vmService,
    required String? isolateId,
  }) async {
    const extensionName = 'ext.ui.window.getSkiaEstimateRasterCacheMemory';
    if (vmService == null || isolateId == null || !isSupported(extensionName)) {
      return null;
    }
    try {
      final response = await vmService.callServiceExtension(
        extensionName,
        isolateId: isolateId,
      );
      final json = response.json;
      if (json != null && json.containsKey('result')) {
        return json['result'] as int?;
      }
    } catch (e) {
      stderr.writeln(
          '[ServiceExtensionRegistry] Raster cache memory query unavailable: $e');
    }
    return null;
  }

  /// Safely executes [extensionRPC] only if registered in the active target isolate.
  ///
  /// Returns `null` if the extension is unsupported or fails with RPC -32601.
  Future<Response?> callIfSupported(
    VmService? vmService,
    String extensionRPC, {
    required String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    if (vmService == null || isolateId == null || !isSupported(extensionRPC)) {
      return null;
    }
    try {
      return await vmService.callServiceExtension(
        extensionRPC,
        isolateId: isolateId,
        args: args,
      );
    } on RPCError catch (e) {
      if (e.code == -32601 ||
          e.message.contains('Method not found') ||
          e.message.contains('Unknown method')) {
        stderr.writeln(
            '[ServiceExtensionRegistry] Extension "$extensionRPC" is unavailable (${e.message}).');
        _activeRPCs.remove(extensionRPC);
        return null;
      }
      rethrow;
    } catch (e) {
      stderr.writeln(
          '[ServiceExtensionRegistry] Error calling extension "$extensionRPC": $e');
      return null;
    }
  }

  /// Disposes active stream subscriptions.
  Future<void> dispose() async {
    await _streamSub?.cancel();
    _streamSub = null;
    _activeRPCs.clear();
  }
}
