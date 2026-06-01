part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for connecting to and disconnecting from a running Flutter app.
extension ConnectionHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleConnect(CallToolRequest req) async {
    try {
      final uri =
          (req.arguments!['uri'] ?? req.arguments!['vmServiceUri']) as String;
      stderr.writeln('[mcp:connect] Attempting connection to: $uri');
      _vmServiceUri = uri;
      _workspaceRoot = req.arguments?['workspace_root'] as String?;

      if (_workspaceRoot != null) {
        _pathResolver = PathResolver(_workspaceRoot!);
      }

      final wsUri = _normalizeToWsUri(uri);
      stderr.writeln('[mcp] Connecting to VM Service: $wsUri');

      _vmService = await vmServiceConnectUri(wsUri);

      final vm = await _vmService!.getVM();
      if (vm.isolates == null || vm.isolates!.isEmpty) {
        return CallToolResult(
          content: [
            TextContent(
                text:
                    'Connection failed: No active isolates found in the Dart VM.')
          ],
          isError: true,
        );
      }
      _isolateId = vm.isolates!.first.id!;
      final ver = await _vmService!.getVersion();

      // Clear existing subscriptions and start buffering streams
      _startLogging();

      // Enable HTTP timeline logging automatically
      try {
        await _vmService!.callServiceExtension(
          'ext.dart.io.httpEnableTimelineLogging',
          isolateId: _isolateId,
          args: {'enabled': 'true'},
        );
      } catch (_) {
        // Fallback for environments without HTTP timeline logging extension
      }

      return CallToolResult(
        content: [
          TextContent(
              text: 'Successfully connected to VM Service.\n'
                  '- VM version: ${ver.major}.${ver.minor}\n'
                  '- Main Isolate: ${vm.isolates!.first.name} ($_isolateId)\n'
                  '- Workspace Root configured: ${_workspaceRoot ?? "None"}')
        ],
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Connection failed: $e')],
        isError: true,
      );
    }
  }

  void _startLogging() {
    _cleanupStreams();
    _logBuffer.clear();

    // Subscribe to stdout stream
    _vmService!.streamListen(EventStreams.kStdout).then((_) {
      _stdoutSub = _vmService!.onStdoutEvent.listen((Event event) {
        final bytes = event.bytes;
        if (bytes != null) {
          try {
            final decoded = utf8.decode(base64.decode(bytes));
            _addToLogBuffer('[STDOUT] $decoded');
          } catch (_) {}
        }
      });
    }).catchError((_) {});

    // Subscribe to stderr stream
    _vmService!.streamListen(EventStreams.kStderr).then((_) {
      _stderrSub = _vmService!.onStderrEvent.listen((Event event) {
        final bytes = event.bytes;
        if (bytes != null) {
          try {
            final decoded = utf8.decode(base64.decode(bytes));
            _addToLogBuffer('[STDERR] $decoded');
          } catch (_) {}
        }
      });
    }).catchError((_) {});

    // Subscribe to developer logs stream
    _vmService!.streamListen(EventStreams.kLogging).then((_) {
      _loggingSub = _vmService!.onLoggingEvent.listen((Event event) {
        final logRecord = event.logRecord;
        if (logRecord != null) {
          final messageRef = logRecord.message;
          final value = messageRef?.valueAsString ?? '';
          final loggerName = logRecord.loggerName?.valueAsString ?? 'log';
          _addToLogBuffer('[$loggerName] $value');
        }
      });
    }).catchError((_) {});
  }

  void _addToLogBuffer(String message) {
    final lines = message.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      if (line.trim().isNotEmpty) {
        _logBuffer.add(line);
      }
    }
    if (_logBuffer.length > 200) {
      _logBuffer.removeRange(0, _logBuffer.length - 200);
    }
  }

  Future<CallToolResult> _handleListRunningApps(CallToolRequest req) async {
    try {
      stderr.writeln('[mcp:list_running_apps] Scanning for active apps...');
      final runningApps = await discoverActiveApps();
      if (runningApps.isEmpty) {
        return CallToolResult(
          content: [
            TextContent(text: 'No active Flutter VM service ports discovered.')
          ],
        );
      }

      final reportBuffer = StringBuffer('### Discovered Active Apps\n');
      for (final app in runningApps) {
        reportBuffer.writeln('- **Project**: ${app.projectName}');
        reportBuffer.writeln('  - **URI**: `${app.serviceUri}`');
        reportBuffer.writeln('  - **Config Path**: `${app.configPath}`');
      }

      return CallToolResult(
        content: [TextContent(text: reportBuffer.toString())],
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Failed to discover active apps: $e')],
        isError: true,
      );
    }
  }

  Future<CallToolResult> _handleAutodiscover(CallToolRequest req) async {
    try {
      final workspaceRoot = req.arguments?['workspace_root'] as String?;
      stderr.writeln(
          '[mcp:autodiscover] Starting auto-discovery, workspace_root=$workspaceRoot');
      final runningApps = await discoverActiveApps();
      stderr.writeln('[mcp:autodiscover] Found ${runningApps.length} app(s)');

      if (runningApps.isEmpty) {
        return CallToolResult(
          content: [
            TextContent(
                text: 'No active Flutter applications were discovered. '
                    'Please make sure your app is running in debug mode, or connect manually using connect_to_app.')
          ],
          isError: true,
        );
      }

      if (runningApps.length == 1) {
        final app = runningApps.first;
        final arguments = {
          'uri': app.serviceUri,
          if (workspaceRoot != null) 'workspace_root': workspaceRoot,
        };

        final connectReq = CallToolRequest(
          name: 'connect_to_app',
          arguments: arguments,
        );

        final connectResult = await _handleConnect(connectReq);
        if (connectResult.isError ?? false) {
          return CallToolResult(
            content: [
              TextContent(
                  text:
                      'Found one application (${app.projectName}) at ${app.serviceUri}, but connection failed.\n'
                      'Error: ${connectResult.content.map((c) => c is TextContent ? c.text : c.toString()).join("\n")}')
            ],
            isError: true,
          );
        }

        return CallToolResult(
          content: [
            TextContent(
                text: 'Successfully discovered and connected to application:\n'
                    '- Project Name: ${app.projectName}\n'
                    '- Service URI: ${app.serviceUri}\n'
                    '- Workspace Root: ${workspaceRoot ?? "None"}')
          ],
        );
      }

      final report = StringBuffer(
          'Multiple active Flutter applications were discovered. '
          'Please connect explicitly using the connect_to_app tool with one of the URIs below:\n\n');
      for (final app in runningApps) {
        report.writeln('- **Project**: ${app.projectName}');
        report.writeln('  - **URI**: `${app.serviceUri}`');
      }

      return CallToolResult(
        content: [TextContent(text: report.toString())],
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Discovery failed: $e')],
        isError: true,
      );
    }
  }

  /// Closes the active VM service connection and cancels running streams.
  Future<CallToolResult> _handleDisconnect(CallToolRequest req) async {
    if (_vmService == null) {
      return CallToolResult(
        content: [TextContent(text: 'Not connected to any app.')],
      );
    }
    _cleanupStreams();
    try {
      await _vmService!.dispose();
    } catch (_) {}
    _vmService = null;
    _vmServiceUri = null;
    _isolateId = null;
    return CallToolResult(
      content: [TextContent(text: 'Disconnected from Flutter app.')],
    );
  }

  /// Retrieves VM diagnostics, active isolates, and registered extensions.
  Future<CallToolResult> _handleGetAppInfo(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    try {
      final vm = await _vmService!.getVM();
      final isolate = await _vmService!.getIsolate(_isolateId!);

      double fpsVal = 60.0;
      try {
        final fpsResponse = await _vmService!.callServiceExtension(
          'ext.flutter.getDisplayRefreshRate',
          isolateId: _isolateId,
        );
        fpsVal = (fpsResponse.json?['fps'] as num?)?.toDouble() ?? 60.0;
      } catch (_) {}

      final extensionRPCs = isolate.extensionRPCs ?? [];
      final flutterExtensions =
          extensionRPCs.where((e) => e.startsWith('ext.flutter.')).toList();

      final appInfo = {
        'vm': {
          'name': vm.name,
          'version': vm.version,
          'os': vm.operatingSystem,
          'hostCPU': vm.hostCPU,
          'targetCPU': vm.targetCPU,
          'architectureBits': vm.architectureBits,
          'pid': vm.pid,
        },
        'app': {
          'rootLibrary': isolate.rootLib?.uri ?? 'unknown',
          'libraryCount': isolate.libraries?.length ?? 0,
          'pauseState': isolate.pauseEvent?.kind ?? 'unknown',
          'displayRefreshRate': fpsVal,
        },
        'flutterExtensions': flutterExtensions,
        'isolates': (vm.isolates ?? [])
            .map((i) => {
                  'id': i.id,
                  'name': i.name,
                  'isSystem': i.isSystemIsolate ?? false,
                })
            .toList(),
      };

      return CallToolResult(
        content: [
          TextContent(text: const JsonEncoder.withIndent('  ').convert(appInfo))
        ],
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Failed to retrieve app details: $e')],
        isError: true,
      );
    }
  }
}
