part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for connecting to and disconnecting from a running Flutter app.
extension ConnectionHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleConnect(CallToolRequest req) async {
    final rawUri =
        (req.arguments!['uri'] ?? req.arguments!['vmServiceUri']) as String;
    try {
      stderr.writeln('[mcp:connect] Attempting connection to: $rawUri');
      _workspaceRoot = req.arguments?['workspace_root'] as String?;

      if (_workspaceRoot != null) {
        _pathResolver = PathResolver(_workspaceRoot!);
      }

      String uriToConnect = rawUri;
      if (_isDtdUri(rawUri)) {
        try {
          uriToConnect = await _resolveDtdToVmServiceUri(rawUri);
          stderr.writeln(
              '[mcp:connect] DTD resolved VM Service URI: $uriToConnect');
        } catch (e) {
          return CallToolResult(
            content: [
              TextContent(
                text:
                    'Connection failed: Failed to resolve DTD URI to VM Service URI: $e\n'
                    'Please verify that DTD is running and has connected apps.',
              )
            ],
            isError: true,
          );
        }
      }

      _vmServiceUri = uriToConnect;
      final wsUri = _normalizeToWsUri(uriToConnect);
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

      // Subscribe to the Service stream NOW (before _startLogging) so that the
      // VM's replayed ServiceRegistered burst is received synchronously.
      // The VM Protocol guarantees that when a client calls streamListen('Service')
      // it immediately receives a ServiceRegistered event for every service that
      // is already registered — this is how DevTools seeds its own map.
      // We await the subscription, attach the listener, then wait a short drain
      // window so the replay events populate _registeredMethodsForService before
      // connect() returns and the caller invokes hot_restart / hot_reload.
      try {
        await _vmService!.streamListen(EventStreams.kService);
        _serviceStreamSub = _vmService!.onServiceEvent.listen((Event event) {
          final service = event.service;
          final method = event.method;
          if (service == null || method == null) return;
          if (event.kind == EventKind.kServiceRegistered) {
            _registeredMethodsForService[service] = method;
            stderr.writeln(
                '[mcp:service] Registered service: $service -> $method');
          } else if (event.kind == EventKind.kServiceUnregistered) {
            _registeredMethodsForService.remove(service);
            stderr.writeln('[mcp:service] Unregistered service: $service');
          }
        });
        // Drain window: give the event loop a tick to deliver the replayed
        // ServiceRegistered events before we return from connect.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        stderr.writeln(
            '[mcp:connect] Service stream seeded: ${_registeredMethodsForService.keys.toList()}');
      } catch (_) {
        // Service stream unavailable — continue without registered method lookup.
      }

      // Clear existing I/O subscriptions and start buffering streams
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
      if (e is RPCError && e.code == -32601) {
        return CallToolResult(
          content: [
            TextContent(
              text:
                  'Connection failed: the URI does not respond as a VM Service endpoint.\n'
                  'If you passed a Dart Tooling Daemon URI, run discover_apps instead.\n'
                  'URI tried: $rawUri',
            )
          ],
          isError: true,
        );
      }
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
            _addToLogBuffer('[STDOUT]', decoded);
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
            _addToLogBuffer('[STDERR]', decoded);
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
          _addToLogBuffer('[$loggerName]', value);
        }
      });
    }).catchError((_) {});

    // Subscribe to the Service stream to track dynamically registered service methods.
    // NOTE: The Service stream is subscribed eagerly in _handleConnect so that
    // replay events for already-registered services (hotRestart, reloadSources)
    // are captured before connect() returns. Here we only subscribe if the
    // subscription was not already set up (e.g. on reconnect after cleanup).
    if (_serviceStreamSub == null) {
      _vmService!.streamListen(EventStreams.kService).then((_) {
        _serviceStreamSub = _vmService!.onServiceEvent.listen((Event event) {
          final service = event.service;
          final method = event.method;
          if (service == null || method == null) return;
          if (event.kind == EventKind.kServiceRegistered) {
            _registeredMethodsForService[service] = method;
            stderr.writeln(
                '[mcp:service] Registered service: $service -> $method');
          } else if (event.kind == EventKind.kServiceUnregistered) {
            _registeredMethodsForService.remove(service);
            stderr.writeln('[mcp:service] Unregistered service: $service');
          }
        });
      }).catchError((_) {});
    }
  }

  void _addToLogBuffer(String prefix, String message) {
    final lines = message.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final formatted = '$prefix $trimmed';
      if (formatted == _lastLogLine) {
        _duplicateLogCount++;
        if (_logBuffer.isNotEmpty) {
          _logBuffer.removeLast();
        }
        _logBuffer.add('$formatted (repeated ${_duplicateLogCount + 1} times)');
      } else {
        _lastLogLine = formatted;
        _duplicateLogCount = 0;
        _logBuffer.add(formatted);
      }
    }
    if (_logBuffer.length > 200) {
      _logBuffer.removeRange(0, _logBuffer.length - 200);
    }
  }

  Future<CallToolResult> _handleAutodiscover(CallToolRequest req) async {
    final workspaceRoot = req.arguments?['workspace_root'] as String?;
    final autoConnect = req.arguments?['autoConnect'] as bool? ?? true;
    stderr.writeln(
        '[mcp:autodiscover] Starting auto-discovery, workspace_root=$workspaceRoot, autoConnect=$autoConnect');
    final runningApps = await discoverActiveApps();
    stderr.writeln('[mcp:autodiscover] Found ${runningApps.length} app(s)');

    if (runningApps.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
              text: 'No active Flutter applications were discovered. '
                  'Please make sure your app is running in debug mode, or connect manually using connect.')
        ],
        isError: true,
      );
    }

    if (!autoConnect) {
      final reportBuffer = StringBuffer('### Discovered Active Apps\n');
      for (final app in runningApps) {
        reportBuffer.writeln('- **Project**: ${app.projectName}');
        reportBuffer.writeln('  - **URI**: `${app.serviceUri}`');
        reportBuffer.writeln('  - **Config Path**: `${app.configPath}`');
      }
      return CallToolResult(
        content: [TextContent(text: reportBuffer.toString())],
      );
    }

    if (runningApps.length == 1) {
      final app = runningApps.first;
      final arguments = {
        'uri': app.serviceUri,
        if (workspaceRoot != null) 'workspace_root': workspaceRoot,
      };

      final connectReq = CallToolRequest(
        name: 'connect',
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
        'Please connect explicitly using the connect tool with one of the URIs below:\n\n');
    for (final app in runningApps) {
      report.writeln('- **Project**: ${app.projectName}');
      report.writeln('  - **URI**: `${app.serviceUri}`');
    }

    return CallToolResult(
      content: [TextContent(text: report.toString())],
    );
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
  }
}
