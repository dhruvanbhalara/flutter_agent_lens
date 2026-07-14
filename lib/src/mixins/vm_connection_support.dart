import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/path_resolver.dart';
import 'package:flutter_agent_lens/src/utils/workspace_package_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';

/// Base support mixin providing VM connection management, isolate management,
/// and common schema definitions for Flutter Agent Lens MCP tools.
base mixin VmConnectionSupport on MCPServer, ToolsSupport {
  static final _lineNumberSuffix = RegExp(r':(\d+)$');
  static final _pubspecNamePattern = RegExp(r'(?:^|\n)name:\s*([A-Za-z0-9_]+)');

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

  /// Cached project package name (e.g. 'my_app' from 'package:my_app/main.dart').
  String? cachedPackageName;

  /// Resolver for workspace packages.
  WorkspacePackageResolver? packageResolver;

  /// Cache for high-frequency isBuiltInWidget lookups.
  final Map<String, bool> isBuiltInWidgetCache = {};

  /// Tracks dynamically registered service methods (e.g. 'hotRestart' -> 's0.hotRestart').
  final Map<String, String> registeredMethodsForService = {};

  /// Subscription to the VM Service's stream of service registration events.
  // The subscription is managed at the class level and cancelled in cleanupStreams.
  // ignore: cancel_subscriptions
  StreamSubscription<Event>? serviceStreamSub;

  /// Server-wide response format preference (markdown or json).
  String _responseFormat =
      Platform.environment['MCP_RESPONSE_FORMAT'] ?? 'markdown';

  /// Current response format.
  String get responseFormat => _responseFormat;
  set responseFormat(String value) => _responseFormat = value;

  /// Performs cleanup operations on active streams and daemon clients.
  FutureOr<void> cleanupStreams() {}

  /// Registers all tools requiring active VM connection.
  void registerConnectedTools();

  /// Unregisters all tools requiring active VM connection.
  void unregisterConnectedTools();

  /// Returns a schema for a duration parameter.
  NumberSchema durationSchema({double defaultValue = 3.0}) {
    return NumberSchema(
      description:
          'Duration to watch/profile in seconds (default: $defaultValue).',
    );
  }

  /// Returns a schema definition for tools requiring a limit parameter.
  IntegerSchema limitSchema({int defaultValue = 20, int max = 200}) {
    return IntegerSchema(
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

  @override
  void registerTool(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) impl, {
    bool validateArguments = true,
  }) {
    final mcpTool = McpTool.fromName(tool.name);
    if (mcpTool == null) {
      throw ArgumentError('Unknown tool name: ${tool.name}');
    }

    final requiresConnection = mcpTool.requiresConnection;

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
                        text:
                            '${mcpTool.name} execution failed (retry): $retryErr')
                  ],
                  isError: true,
                );
              }
            }
          }
          stderr.writeln('[mcp:${mcpTool.name}] ERROR: $e');
          stderr.writeln('[mcp:${mcpTool.name}] STACKTRACE: $st');
          return CallToolResult(
            content: [
              TextContent(text: '${mcpTool.name} execution failed: $e')
            ],
            isError: true,
          );
        }
      },
      validateArguments: validateArguments,
    );
  }

  /// Helper to determine if an error is related to garbage collection or isolate sentinels.
  bool _isCollectedError(Object e) {
    return switch (e) {
      SentinelException() => true,
      RPCError(:final code, :final message)
          when code == 106 ||
              message.contains('collected') ||
              message.contains('Sentinel') ||
              message.contains('sentinel') =>
        true,
      final error
          when error.toString().contains('Collected') ||
              error.toString().contains('Sentinel') ||
              error.toString().contains('sentinel') =>
        true,
      _ => false,
    };
  }

  /// Refreshes the active main isolate ID from the running Dart VM.
  ///
  /// Returns `true` if a new isolate ID was found and updated, `false` otherwise.
  Future<bool> refreshIsolateId() async {
    if (vmService == null) return false;
    try {
      final vm = await vmService!.getVM();
      if (vm.isolates case final isolates? when isolates.isNotEmpty) {
        final activeIsolates =
            isolates.where((i) => i.isSystemIsolate != true).toList();
        if (activeIsolates.isNotEmpty) {
          isolateId = activeIsolates.first.id;
        } else {
          isolateId = isolates.first.id;
        }
        cachedLibraryId = null;
        cachedPackageName = null;
        packageResolver = null;
        isBuiltInWidgetCache.clear();
        stderr.writeln(
            '[mcp] Dynamically refreshed active isolate ID: $isolateId');
        return true;
      }
    } catch (err) {
      stderr.writeln('[mcp] Failed to refresh isolate ID: $err');
    }
    return false;
  }

  /// Serializes response data as Markdown or JSON based on [responseFormat].
  CallToolResult serializeDualFormat({
    required String title,
    required String markdownBody,
    required Map<String, dynamic> structuredData,
  }) {
    final fmt = responseFormat;
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
    final parsed = Uri.tryParse(uri);
    if (parsed != null && parsed.pathSegments.isNotEmpty) {
      final nonMin = parsed.pathSegments.where((s) => s.isNotEmpty).toList();
      if (nonMin.isNotEmpty && nonMin.first != 'ws') {
        return false; // Path contains a token segment (e.g. /buHq_nWQVRM=/)
      }
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
      ws = ws.replaceFirst(RegExp(r'/?$'), '/ws');
    }
    return ws;
  }

  /// Resolves a DTD connection URI to an active application VM Service WebSocket URI.
  Future<String> resolveDtdToVmServiceUri(String dtdUri) async {
    final wsDtd = normalizeToWsUri(dtdUri);
    stderr.writeln(
        '[mcp:connect] Connecting to DTD WebSocket to resolve VM Service: $wsDtd');
    final WebSocket ws;
    try {
      ws = await WebSocket.connect(wsDtd).timeout(const Duration(seconds: 3));
    } catch (e) {
      throw StateError('Failed to connect to DTD at $wsDtd: $e');
    }

    final completer = Completer<String>();
    ws.listen((message) {
      try {
        final decoded = jsonDecode(message as String);
        if (decoded
            case {
              'id': 1001,
              'result': {
                'vmServices': [
                  {'exposedUri': final String vmUri} ||
                      {'uri': final String vmUri},
                  ...
                ]
              }
            }) {
          completer.complete(vmUri);
          unawaited(ws.close());
        } else if (decoded case {'id': 1001, 'result': {'vmServices': []}}) {
          completer.completeError(
              StateError('DTD reports no running VM Services connected.'));
          unawaited(ws.close());
        } else if (decoded case {'id': 1001, 'error': final error}) {
          completer.completeError(StateError('DTD returned RPC error: $error'));
          unawaited(ws.close());
        } else if (decoded case {'id': 1001}) {
          completer
              .completeError(StateError('Invalid response format from DTD.'));
          unawaited(ws.close());
        }
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
        unawaited(ws.close());
      }
    }, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
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
      'params': <String, dynamic>{},
    };
    ws.add(jsonEncode(request));

    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () {
      unawaited(ws.close());
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

    // Prioritize the entry point library ending with main.dart (e.g. package:test_app/main.dart)
    for (final lib in libraries) {
      final uri = lib.uri ?? '';
      if (uri.startsWith('package:') && uri.endsWith('main.dart')) {
        final libId = lib.id;
        if (libId != null) {
          cachedLibraryId = libId;
          return libId;
        }
      }
    }

    // Return the main application library ID if found, otherwise the first library.
    for (final lib in libraries) {
      final uri = lib.uri ?? '';
      if (uri.startsWith('package:') && !uri.contains('package:flutter/')) {
        final libId = lib.id;
        if (libId != null) {
          cachedLibraryId = libId;
          return libId;
        }
      }
    }

    final firstId = libraries.first.id;
    if (firstId == null) {
      throw StateError('Library has no ID');
    }
    cachedLibraryId = firstId;
    return firstId;
  }

  /// Get the project's package name.
  /// Reads name from pubspec.yaml if workspaceRoot exists; falls back to isolate libraries.
  Future<String?> getProjectPackageName() async {
    if (cachedPackageName != null) return cachedPackageName;

    // Read from pubspec.yaml
    if (workspaceRoot case final root? when root.isNotEmpty) {
      try {
        final file = File(p.join(root, 'pubspec.yaml'));
        if (file.existsSync()) {
          final content = await file.readAsString();
          final match = _pubspecNamePattern.firstMatch(content);
          if (match != null) {
            return cachedPackageName = match.group(1);
          }
        }
      } catch (_) {}
    }

    // Fallback: parse isolate libraries
    final activeIsolateId = isolateId;
    if (vmService == null || activeIsolateId == null) return null;
    try {
      final isolate = await vmService!.getIsolate(activeIsolateId);
      final libraries = isolate.libraries ?? [];
      for (final lib in libraries) {
        final uri = lib.uri ?? '';
        if (uri.startsWith('package:') && uri.endsWith('main.dart')) {
          return cachedPackageName =
              uri.substring(8, uri.indexOf('/')); // 'package:'.length == 8
        }
      }
      // Fallback: use first non-flutter package URI
      for (final lib in libraries) {
        final uri = lib.uri ?? '';
        if (uri.startsWith('package:') && !uri.startsWith('package:flutter/')) {
          return cachedPackageName = uri.substring(8, uri.indexOf('/'));
        }
      }
    } catch (_) {}
    return null;
  }

  /// Format byte counts to human readable strings.
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

  /// Load local and external packages using WorkspacePackageResolver.
  Future<void> loadWorkspacePackages() async {
    if (workspaceRoot case final root? when root.isNotEmpty) {
      packageResolver = WorkspacePackageResolver(root);
      await packageResolver!.load();
      isBuiltInWidgetCache.clear();
    }
  }

  /// Checks if the path belongs to a built-in/SDK widget or external package.
  bool isBuiltInWidget(String rawFilePath, {String? projectName}) {
    final cleanPath = stripLineNumber(rawFilePath);
    if (isBuiltInWidgetCache.containsKey(cleanPath)) {
      return isBuiltInWidgetCache[cleanPath]!;
    }
    final result = _evaluateIsBuiltIn(cleanPath, projectName: projectName);
    isBuiltInWidgetCache[cleanPath] = result;
    return result;
  }

  bool _evaluateIsBuiltIn(String cleanPath, {String? projectName}) {
    var path = cleanPath;

    // Convert file URIs
    if (path.startsWith('file:')) {
      try {
        path = Uri.parse(path).toFilePath();
      } catch (_) {
        if (path.startsWith('file:///')) {
          path = path.substring(7);
        } else if (path.startsWith('file://')) {
          path = path.substring(7);
        } else if (path.startsWith('file:')) {
          path = path.substring(5);
        }
      }
    }

    // Scheme checks
    if (path.startsWith('dart:') ||
        path.startsWith('org-dartlang-sdk:') ||
        path.startsWith('native')) {
      return true;
    }

    // Package URIs
    if (path.startsWith('package:')) {
      final slashIdx = path.indexOf('/');
      if (slashIdx != -1) {
        final pkgName = path.substring(8, slashIdx);
        final resolver = packageResolver;
        if (resolver != null) {
          if (resolver.localPackages.contains(pkgName)) return false;
          if (resolver.externalPackages.contains(pkgName)) return true;
        }
      }

      // Fallback
      if (projectName case final name? when name.isNotEmpty) {
        return !path.startsWith('package:$name/');
      }
      // Exclude core flutter packages
      return path.startsWith('package:flutter/') ||
          path.startsWith('package:flutter_test/');
    }

    // Make relative paths absolute using workspaceRoot
    if (p.isRelative(path)) {
      if (workspaceRoot case final root? when root.isNotEmpty) {
        path = p.join(root, path);
      }
    }

    // Boundary check against workspaceRoot
    if (workspaceRoot case final root? when root.isNotEmpty) {
      try {
        final canonicalRoot = p.canonicalize(root);
        final canonicalPath = p.canonicalize(path);
        return !canonicalPath.startsWith(canonicalRoot);
      } catch (_) {
        // Treat as external if canonicalization fails
        return true;
      }
    }

    // Fallback if workspaceRoot is null
    try {
      final sdkPath =
          p.canonicalize(p.dirname(p.dirname(Platform.resolvedExecutable)));
      if (p.canonicalize(path).startsWith(sdkPath)) {
        return true;
      }
    } catch (_) {}

    final lowerPath = path.toLowerCase();
    if (lowerPath.contains('pub-cache') ||
        lowerPath.contains('pub_cache') ||
        lowerPath.contains('.puro') ||
        lowerPath.contains('.fvm') ||
        lowerPath.contains('.mise') ||
        lowerPath.contains('sky_engine') ||
        lowerPath.contains('/packages/flutter/')) {
      return true;
    }

    return false;
  }

  /// Strip ':lineNumber' suffix.
  String stripLineNumber(String location) {
    final match = _lineNumberSuffix.firstMatch(location);
    if (match != null) {
      return location.substring(0, match.start);
    }
    return location;
  }
}
