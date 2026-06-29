import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import '../enums/mcp_tool.dart';
import '../path_resolver.dart';

/// Base support mixin providing VM connection management, isolate management,
/// and common schema definitions for Flutter Agent Lens MCP tools.
base mixin VmConnectionSupport on MCPServer, ToolsSupport {
  /// The active connection to the Dart VM Service.
  VmService? vmService;

  /// The active VM Service URI.
  String? vmServiceUri;

  /// The active main isolate ID.
  String? isolateId;

  /// The absolute path to the local Flutter project workspace root.
  String? workspaceRoot;

  /// Resolves VM-reported file URIs to local absolute paths in the workspace.
  PathResolver? pathResolver;

  /// Cached main library ID of the target application.
  String? cachedLibraryId;

  /// Tracks dynamically registered service methods (e.g. 'hotRestart' -> 's0.hotRestart').
  final Map<String, String> registeredMethodsForService = {};

  /// Subscription to the VM Service's stream of service registration events.
  StreamSubscription? serviceStreamSub;

  /// Performs cleanup operations on active streams and daemon clients.
  void cleanupStreams() {}

  /// Returns a schema definition for tools requiring a duration parameter.
  NumberSchema durationSchema({double defaultValue = 3.0}) {
    return NumberSchema(
      description:
          'Duration to watch/profile in seconds (default: $defaultValue).',
    );
  }

  /// Returns a schema definition for tools requiring a format parameter.
  StringSchema get formatSchema => StringSchema(
        description: 'Response format: markdown or json (default: markdown).',
      );

  /// Returns a schema definition for tools requiring a limit parameter.
  NumberSchema limitSchema({double defaultValue = 20.0, double max = 200.0}) {
    return NumberSchema(
      description:
          'Maximum elements to return (default: $defaultValue, max: $max).',
    );
  }

  /// Returns an empty object schema.
  ObjectSchema emptySchema() => ObjectSchema(properties: {});

  /// Returns a standard error result indicating no active connection is established.
  CallToolResult notConnected() {
    return CallToolResult(
      content: [
        TextContent(
            text: 'Not connected to a running application. Run connect first.')
      ],
      isError: true,
    );
  }

  /// List of tools that do not require an active application VM connection.
  static final Set<McpTool> _offlineTools = {
    McpTool.connect,
    McpTool.discoverApps,
    McpTool.connectDtd,
    McpTool.getActiveLocation,
    McpTool.validateDeepLinks,
    McpTool.listSnapshots,
    McpTool.analyzeBundleSize,
  };

  @override
  void registerTool(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) impl, {
    bool validateArguments = true,
  }) {
    final mcpTool = McpTool.values.firstWhere(
      (e) => e.name == tool.name,
      orElse: () => throw ArgumentError('Unknown tool name: ${tool.name}'),
    );

    final requiresConnection = !_offlineTools.contains(mcpTool);

    super.registerTool(
      tool,
      (req) async {
        if (requiresConnection && vmService != null && isolateId == null) {
          await refreshIsolateId();
        }
        if (requiresConnection && (vmService == null || isolateId == null)) {
          return notConnected();
        }
        try {
          return await impl(req);
        } catch (e, st) {
          if (requiresConnection && _isCollectedError(e)) {
            stderr.writeln(
                '[mcp:${mcpTool.name}] Detected collected/sentinel error, attempting to refresh isolate ID and retry...');
            final refreshed = await refreshIsolateId();
            if (refreshed) {
              try {
                return await impl(req);
              } catch (retryErr, retrySt) {
                stderr.writeln('[mcp:${mcpTool.name}] Retry failed: $retryErr');
                stderr.writeln('[mcp:${mcpTool.name}] STACKTRACE: $retrySt');
                return CallToolResult(
                  content: [
                    TextContent(
                        text: '${mcpTool.name} execution failed (retry): $retryErr')
                  ],
                  isError: true,
                );
              }
            }
          }
          stderr.writeln('[mcp:${mcpTool.name}] ERROR: $e');
          stderr.writeln('[mcp:${mcpTool.name}] STACKTRACE: $st');
          return CallToolResult(
            content: [TextContent(text: '${mcpTool.name} execution failed: $e')],
            isError: true,
          );
        }
      },
      validateArguments: validateArguments,
    );
  }


  /// Helper to determine if an error is related to garbage collection or isolate sentinels.
  bool _isCollectedError(Object e) {
    final str = e.toString();
    return str.contains('Collected') ||
        str.contains('Sentinel') ||
        str.contains('sentinel');
  }

  /// Refreshes the active main isolate ID from the running Dart VM.
  ///
  /// Returns `true` if a new isolate ID was found and updated, `false` otherwise.
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

  /// Serializes response data into either a Markdown table/text layout
  /// or a raw JSON code block, based on request format or environment variables.
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

  /// Checks if a URI is a Dart Tooling Daemon (DTD) endpoint or a direct VM Service URI.
  bool isDtdUri(String uri) {
    final cleaned = uri.trim().toLowerCase();
    if (cleaned.endsWith('/ws') ||
        cleaned.endsWith('/ws/') ||
        cleaned.contains('/ws?')) {
      return false;
    }
    if (cleaned.contains('auth_token=')) {
      return false;
    }
    return true;
  }

  /// Normalizes HTTP or raw WS URIs to standardized WebSocket connection schemes.
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

  /// Resolves a DTD connection URI to an active application VM Service WebSocket URI.
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
        final decoded = jsonDecode(message as String);
        if (decoded case {
          'id': 1001,
          'result': {
            'vmServices': [
              {'exposedUri': String vmUri} || {'uri': String vmUri},
              ...
            ]
          }
        }) {
          completer.complete(vmUri);
          ws.close();
        } else if (decoded case {
          'id': 1001,
          'result': {'vmServices': []}
        }) {
          completer.completeError(
              StateError('DTD reports no running VM Services connected.'));
          ws.close();
        } else if (decoded case {
          'id': 1001,
          'error': final error
        }) {
          completer.completeError(
              StateError('DTD returned RPC error: $error'));
          ws.close();
        } else if (decoded case {'id': 1001}) {
          completer.completeError(
              StateError('Invalid response format from DTD.'));
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

  /// Locates the library ID corresponding to the main application package to run expression evaluations.
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

  /// Formats raw byte counts into human-readable strings (e.g. KB, MB, GB).
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
