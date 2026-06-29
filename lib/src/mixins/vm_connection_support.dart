import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import '../path_resolver.dart';

base mixin VmConnectionSupport on MCPServer, ToolsSupport {
  VmService? vmService;
  String? vmServiceUri;
  String? isolateId;
  String? workspaceRoot;
  PathResolver? pathResolver;
  String? cachedLibraryId;

  // Tracks dynamically registered service methods (e.g. 'hotRestart' -> 's0.hotRestart')
  final Map<String, String> registeredMethodsForService = {};
  StreamSubscription? serviceStreamSub;

  void cleanupStreams() {}

  NumberSchema durationSchema({double defaultValue = 3.0}) {
    return NumberSchema(
      description:
          'Duration to watch/profile in seconds (default: $defaultValue).',
    );
  }

  NumberSchema limitSchema({double defaultValue = 20.0, double max = 200.0}) {
    return NumberSchema(
      description:
          'Maximum elements to return (default: $defaultValue, max: $max).',
    );
  }

  ObjectSchema emptySchema() => ObjectSchema(properties: {});

  CallToolResult notConnected() {
    return CallToolResult(
      content: [
        TextContent(
            text: 'Not connected to a running application. Run connect first.')
      ],
      isError: true,
    );
  }

  Future<CallToolResult> Function(CallToolRequest) wrapToolCall(
    String toolName,
    FutureOr<CallToolResult> Function(CallToolRequest) handler, {
    bool requiresConnection = true,
  }) {
    return (CallToolRequest req) async {
      if (requiresConnection && vmService != null && isolateId == null) {
        await refreshIsolateId();
      }
      if (requiresConnection && (vmService == null || isolateId == null)) {
        return notConnected();
      }
      try {
        return await handler(req);
      } catch (e, st) {
        if (requiresConnection && _isCollectedError(e)) {
          stderr.writeln(
              '[mcp:$toolName] Detected collected/sentinel error, attempting to refresh isolate ID and retry...');
          final refreshed = await refreshIsolateId();
          if (refreshed) {
            try {
              return await handler(req);
            } catch (retryErr, retrySt) {
              stderr.writeln('[mcp:$toolName] Retry failed: $retryErr');
              stderr.writeln('[mcp:$toolName] STACKTRACE: $retrySt');
              return CallToolResult(
                content: [
                  TextContent(
                      text: '$toolName execution failed (retry): $retryErr')
                ],
                isError: true,
              );
            }
          }
        }
        stderr.writeln('[mcp:$toolName] ERROR: $e');
        stderr.writeln('[mcp:$toolName] STACKTRACE: $st');
        return CallToolResult(
          content: [TextContent(text: '$toolName execution failed: $e')],
          isError: true,
        );
      }
    };
  }

  bool _isCollectedError(Object e) {
    final str = e.toString();
    return str.contains('Collected') ||
        str.contains('Sentinel') ||
        str.contains('sentinel');
  }

  Future<bool> refreshIsolateId() async {
    if (vmService == null) return false;
    try {
      final vm = await vmService!.getVM();
      if (vm.isolates != null && vm.isolates!.isNotEmpty) {
        final activeIsolates =
            vm.isolates!.where((i) => i.isSystemIsolate != true).toList();
        if (activeIsolates.isNotEmpty) {
          isolateId = activeIsolates.first.id;
        } else {
          isolateId = vm.isolates!.first.id;
        }
        cachedLibraryId = null;
        stderr.writeln(
            '[mcp] Dynamically refreshed active isolate ID: $isolateId');
        return true;
      }
    } catch (err) {
      stderr.writeln('[mcp] Failed to refresh isolate ID: $err');
    }
    return false;
  }

  CallToolResult serializeDualFormat({
    required String title,
    required String markdownBody,
    required Map<String, dynamic> structuredData,
    String? format,
  }) {
    final fmt =
        format ?? Platform.environment['MCP_RESPONSE_FORMAT'] ?? 'markdown';
    final contentBuffer = StringBuffer();

    if (fmt == 'json') {
      contentBuffer
        ..writeln('```json')
        ..writeln(const JsonEncoder.withIndent('  ').convert(structuredData))
        ..writeln('```');
    } else {
      contentBuffer
        ..writeln(title)
        ..writeln()
        ..writeln(markdownBody);
    }

    return CallToolResult(
      content: [
        TextContent(text: contentBuffer.toString().trim()),
      ],
    );
  }

  bool isDtdUri(String uri) {
    final cleaned = uri.trim().toLowerCase();
    return !cleaned.endsWith('/ws') &&
        !cleaned.endsWith('/ws/') &&
        !cleaned.contains('/ws?');
  }

  String normalizeToWsUri(String uri) {
    var ws = uri.trim();
    if (!ws.startsWith('ws')) {
      ws = ws
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://');
    }
    if (!isDtdUri(uri) && !ws.endsWith('/ws')) {
      ws = ws.replaceAll(RegExp(r'/?$'), '/ws');
    }
    return ws;
  }

  Future<String> resolveDtdToVmServiceUri(String dtdUri) async {
    final wsDtd = normalizeToWsUri(dtdUri);
    stderr.writeln(
        '[mcp:connect] Connecting to DTD WebSocket to resolve VM Service: $wsDtd');
    WebSocket ws;
    try {
      ws = await WebSocket.connect(wsDtd).timeout(const Duration(seconds: 3));
    } catch (e) {
      throw StateError('Failed to connect to DTD at $wsDtd: $e');
    }

    final completer = Completer<String>();
    ws.listen((message) {
      try {
        final decoded = jsonDecode(message as String) as Map<String, dynamic>;
        if (decoded['id'] == 1001) {
          final result = decoded['result'] as Map<String, dynamic>?;
          if (result != null) {
            final services = result['vmServices'] as List?;
            if (services != null && services.isNotEmpty) {
              final firstService = services.first as Map<String, dynamic>;
              final vmUri =
                  (firstService['exposedUri'] ?? firstService['uri']) as String;
              completer.complete(vmUri);
            } else {
              completer.completeError(
                  StateError('DTD reports no running VM Services connected.'));
            }
          } else if (decoded['error'] != null) {
            completer.completeError(
                StateError('DTD returned RPC error: ${decoded['error']}'));
          } else {
            completer
                .completeError(StateError('Invalid response format from DTD.'));
          }
          ws.close();
        }
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
        ws.close();
      }
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError(e as Object);
    }, onDone: () {
      if (!completer.isCompleted) {
        completer.completeError(
            StateError('DTD connection closed before response was received.'));
      }
    });

    final request = {
      'jsonrpc': '2.0',
      'id': 1001,
      'method': 'ConnectedApps.getVmServices',
      'params': {},
    };
    ws.add(jsonEncode(request));

    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () {
      ws.close();
      throw TimeoutException(
          'Timed out waiting for DTD getVmServices response.');
    });
  }

  Future<String> getEvaluationLibraryId() async {
    if (vmService == null || isolateId == null) {
      throw StateError('Not connected to a running application.');
    }
    if (cachedLibraryId != null) {
      return cachedLibraryId!;
    }

    final isolate = await vmService!.getIsolate(isolateId!);
    final libraries = isolate.libraries ?? [];
    if (libraries.isEmpty) {
      throw StateError('No libraries found in target isolate.');
    }

    // Return the main application library ID if found, otherwise the first library.
    for (final lib in libraries) {
      final uri = lib.uri ?? '';
      if (uri.startsWith('package:') && !uri.contains('package:flutter/')) {
        cachedLibraryId = lib.id;
        return lib.id!;
      }
    }

    cachedLibraryId = libraries.first.id;
    return libraries.first.id!;
  }

  String formatBytes(int bytes) {
    if (bytes == 0) return '0 B';
    final sign = bytes < 0 ? '-' : '';
    var absVal = bytes.abs().toDouble();
    final units = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    while (absVal >= 1024.0 && i < units.length - 1) {
      absVal /= 1024.0;
      i++;
    }
    return '$sign${absVal.toStringAsFixed(2)} ${units[i]}';
  }
}
