import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart' hide Event;
import 'package:vm_service/vm_service_io.dart';
import 'package:dtd/dtd.dart';
import '../enums/mcp_tool.dart';
import '../extensions/call_tool_request_x.dart';
import 'vm_connection_support.dart';
import 'console_logging_support.dart';
import '../port_discovery.dart';
import '../path_resolver.dart';

/// Support mixin providing tools for connecting, disconnecting, retrieving
/// app information, and autodiscovering running Flutter/Dart applications.
base mixin ConnectionSupport
    on
        MCPServer,
        ToolsSupport,
        VmConnectionSupport,
        ConsoleLoggingSupport,
        RootsTrackingSupport {
  /// The active connection to the Dart Tooling Daemon.
  DartToolingDaemon? dtdClient;

  /// The WebSocket URI of the connected Dart Tooling Daemon.
  String? dtdUri;

  /// Registers connection and configuration tools.
  void registerConnectionTools() {
    registerTool(
      Tool(
        name: McpTool.connection.name,
        description:
            'Manage VM Service or DTD connections (details in docs/user_prompt_guide.md).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description: 'Operation (connect, connect_dtd, disconnect).',
            ),
            'uri': StringSchema(
              description: 'WebSocket or HTTP URI.',
            ),
            'vmServiceUri': StringSchema(
              description: 'Alias for uri.',
            ),
            'workspace_root': StringSchema(
              description: 'Flutter project root path.',
            ),
          },
          required: ['action'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
        ),
      ),
      _handleConnection,
    );

    registerTool(
      Tool(
        name: McpTool.discoverApps.name,
        description:
            'Discover running Flutter apps (details in docs/user_prompt_guide.md).',
        inputSchema: ObjectSchema(
          properties: {
            'autoConnect': BooleanSchema(
              description:
                  'Auto-connect to first discovered app (default: true).',
            ),
            'workspace_root': StringSchema(
              description: 'Flutter project root path.',
            ),
          },
        ),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: true,
        ),
      ),
      _handleAutodiscover,
    );

    registerTool(
      Tool(
        name: McpTool.setResponseFormat.name,
        description:
            'Set response format (details in docs/user_prompt_guide.md).',
        inputSchema: ObjectSchema(
          properties: {
            'format': StringSchema(
              description: 'Format (markdown or json).',
            ),
          },
          required: ['format'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
        ),
      ),
      _handleSetResponseFormat,
    );
  }

  /// Registers all connection-dependent DTD tools.
  void registerDtdTools() {
    unregisterTool(McpTool.getActiveLocation.name);
    registerTool(
      Tool(
        name: McpTool.getActiveLocation.name,
        description:
            'Get active editor file path and cursor position when connected via DTD.',
        inputSchema: emptySchema(),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: false,
        ),
      ),
      _handleGetActiveLocation,
    );
  }

  /// Registers post-connection app information tools.
  void registerAppInfoTools() {
    registerTool(
      Tool(
        name: McpTool.getAppInfo.name,
        description:
            'Get VM info, isolates, and extensions for the connected app.',
        inputSchema: ObjectSchema(
          properties: {
            'includeExtensions': BooleanSchema(
              description:
                  'Include the full list of Flutter service extensions (default: false).',
            ),
          },
        ),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: true,
        ),
      ),
      _handleGetAppInfo,
    );
  }

  /// Consolidated connection handler.
  Future<CallToolResult> _handleConnection(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    switch (action) {
      case 'connect':
        return _handleConnect(req);
      case 'connect_dtd':
        return _handleConnectDtd(req);
      case 'disconnect':
        return _handleDisconnect(req);
      default:
        return CallToolResult(
          content: [TextContent(text: 'Unknown action: $action')],
          isError: true,
        );
    }
  }

  /// Handles the connect tool request.
  Future<CallToolResult> _handleConnect(CallToolRequest req) async {
    if (vmService != null) {
      try {
        unregisterConnectedTools();
      } catch (_) {}
      try {
        await vmService!.dispose();
      } catch (_) {}
      vmService = null;
      vmServiceUri = null;
      isolateId = null;
    }

    final rawUri = switch (req.arguments) {
      {'uri': final String uri} => uri,
      {'vmServiceUri': final String uri} => uri,
      _ => throw ArgumentError(
          'Required parameter "uri" or "vmServiceUri" is missing.'),
    };
    final parsed = Uri.tryParse(rawUri);
    if (parsed == null ||
        !{'ws', 'wss', 'http', 'https'}.contains(parsed.scheme)) {
      return CallToolResult(
        content: [
          TextContent(
            text:
                'Invalid URI scheme. Connection URI must use ws, wss, http, or https.',
          )
        ],
        isError: true,
      );
    }
    try {
      stderr.writeln('[mcp:connect] Attempting connection to: $rawUri');
      await _resolveWorkspaceRoot(req);

      String uriToConnect = rawUri;
      if (isDtdUri(rawUri)) {
        try {
          uriToConnect = await _connectAndResolveDtd(rawUri);
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

      vmServiceUri = uriToConnect;
      final wsUri = normalizeToWsUri(uriToConnect);
      stderr.writeln('[mcp] Connecting to VM Service: $wsUri');
      vmService = await vmServiceConnectUri(wsUri).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
            'Timed out connecting to VM Service at $wsUri'),
      );

      unawaited(vmService!.onDone.then((_) {
        stderr.writeln('[mcp] VM Service connection lost.');
        try {
          unregisterConnectedTools();
        } catch (_) {}
        vmService = null;
        isolateId = null;
        vmServiceUri = null;
      }));

      final vm = await vmService!.getVM();
      final isolates = vm.isolates;
      if (isolates == null || isolates.isEmpty) {
        try {
          await vmService!.dispose();
        } catch (_) {}
        vmService = null;
        vmServiceUri = null;
        return CallToolResult(
          content: [
            TextContent(
                text:
                    'Connection failed: No active isolates found in the Dart VM.')
          ],
          isError: true,
        );
      }
      final activeIsolates =
          isolates.where((i) => i.isSystemIsolate != true).toList();
      if (activeIsolates.isNotEmpty) {
        final id = activeIsolates.first.id;
        if (id == null) {
          throw StateError('Isolate has no ID');
        }
        isolateId = id;
      } else {
        final id = isolates.first.id;
        if (id == null) {
          throw StateError('Isolate has no ID');
        }
        isolateId = id;
      }
      final ver = await vmService!.getVersion();

      try {
        serviceStreamSub = vmService!.onServiceEvent.listen((event) {
          final service = event.service;
          final method = event.method;
          if (service == null || method == null) return;
          if (event.kind == EventKind.kServiceRegistered) {
            registeredMethodsForService[service] = method;
            stderr.writeln(
                '[mcp:service] Registered service: $service -> $method');
          } else if (event.kind == EventKind.kServiceUnregistered) {
            registeredMethodsForService.remove(service);
            stderr.writeln('[mcp:service] Unregistered service: $service');
          }
        });
        await vmService!.streamListen(EventStreams.kService);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        stderr.writeln(
            '[mcp:connect] Service stream seeded: ${registeredMethodsForService.keys.toList()}');
      } catch (e) {
        stderr.writeln('[mcp:connect] Error seeding service stream: $e');
      }

      // Clear existing I/O subscriptions and start buffering streams
      await startLogging();

      // Enable HTTP timeline logging automatically
      try {
        await vmService!.callServiceExtension(
          'ext.dart.io.httpEnableTimelineLogging',
          isolateId: isolateId,
          args: {'enabled': 'true'},
        );
      } catch (e) {
        stderr
            .writeln('[mcp:connect] Error enabling HTTP timeline logging: $e');
      }

      final currentIsolates = vm.isolates ?? [];
      final String selectedIsolateName;
      if (currentIsolates.isNotEmpty) {
        selectedIsolateName = currentIsolates
                .firstWhere((i) => i.id == isolateId,
                    orElse: () => currentIsolates.first)
                .name ??
            'unknown';
      } else {
        selectedIsolateName = 'unknown';
      }

      // Register connected tools
      try {
        registerConnectedTools();
      } catch (e) {
        stderr.writeln('[mcp:connect] Error registering connected tools: $e');
      }

      return CallToolResult(
        content: [
          TextContent(
              text: 'Successfully connected to VM Service.\n'
                  '- VM version: ${ver.major}.${ver.minor}\n'
                  '- Main Isolate: $selectedIsolateName ($isolateId)\n'
                  '- Workspace Root configured: ${workspaceRoot ?? "None"}')
        ],
      );
    } catch (e) {
      try {
        await vmService?.dispose();
      } catch (_) {}
      vmService = null;
      vmServiceUri = null;
      isolateId = null;

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

  Future<void> _resolveWorkspaceRoot(CallToolRequest req) async {
    workspaceRoot = req.arg<String>('workspace_root');

    if (workspaceRoot == null || workspaceRoot!.isEmpty) {
      try {
        final clientRoots = await roots;
        if (clientRoots.isNotEmpty) {
          final firstUriStr = clientRoots.first.uri;
          final firstUri = Uri.parse(firstUriStr);
          if (firstUri.isScheme('file')) {
            workspaceRoot = firstUri.toFilePath();
            stderr.writeln(
                '[mcp:connect] Resolved workspace root from client: $workspaceRoot');
          }
        }
      } catch (e) {
        stderr.writeln('[mcp:connect] Error fetching client roots: $e');
      }
    }

    if (workspaceRoot != null) {
      pathResolver = PathResolver(workspaceRoot!);
    }
  }

  Future<String> _connectAndResolveDtd(String rawUri) async {
    final uriToConnect = await resolveDtdToVmServiceUri(rawUri);
    stderr.writeln('[mcp:connect] DTD resolved VM Service URI: $uriToConnect');

    try {
      stderr.writeln(
          '[mcp:connect] Initializing DTD client for DTD URI: $rawUri');
      final parsedDtdUri = Uri.parse(rawUri);
      await dtdClient?.close();
      dtdClient = await DartToolingDaemon.connect(parsedDtdUri);
      dtdUri = rawUri;
      registerDtdTools();
      stderr.writeln('[mcp:connect] DTD client initialized successfully.');
    } catch (dtdErr) {
      stderr.writeln('[mcp:connect] Failed to initialize DTD client: $dtdErr');
    }
    return uriToConnect;
  }

  /// Handles the DTD connection request.
  Future<CallToolResult> _handleConnectDtd(CallToolRequest req) async {
    final uriStr = switch (req.arguments) {
      {'uri': final String uri} => uri,
      {'vmServiceUri': final String uri} => uri,
      _ => null,
    };
    if (uriStr == null) {
      return CallToolResult(
        content: [
          TextContent(text: 'Missing required argument "uri" or "vmServiceUri"')
        ],
        isError: true,
      );
    }
    try {
      stderr.writeln('[mcp:dtd] Connecting to DTD at: $uriStr');
      final uri = Uri.parse(uriStr);
      final client = await DartToolingDaemon.connect(uri);

      try {
        await dtdClient?.close();
      } catch (_) {}

      dtdClient = client;
      dtdUri = uriStr;

      registerDtdTools();

      final services = await client.getRegisteredServices();
      final apps = await client.getVmServices();

      final report =
          StringBuffer('Successfully connected to Dart Tooling Daemon.\n\n');
      report.writeln('Registered Services:');
      for (final service in services.dtdServices) {
        report.writeln('- $service');
      }
      for (final service in services.clientServices) {
        report.writeln('- ${service.name}');
      }
      report.writeln('\nRunning VM Services:');
      for (final app in apps.vmServicesInfos) {
        report
          ..write('- ${app.exposedUri ?? app.uri}')
          ..writeln(app.name != null ? ' (${app.name})' : '');
      }

      return CallToolResult(
        content: [TextContent(text: report.toString().trim())],
      );
    } catch (e) {
      if (dtdClient != null) {
        try {
          await dtdClient!.close();
        } catch (_) {}
        dtdClient = null;
        dtdUri = null;
      }
      return CallToolResult(
        content: [TextContent(text: 'Failed to connect to DTD: $e')],
        isError: true,
      );
    }
  }

  /// Handles the get_active_location tool request.
  Future<CallToolResult> _handleGetActiveLocation(CallToolRequest req) async {
    final client = dtdClient;
    if (client == null) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Not connected to DTD. Run the `connection` tool with action: `connect_dtd` first.')
        ],
        isError: true,
      );
    }

    try {
      final registered = await client.getRegisteredServices();
      String? editorService;
      for (final service in registered.clientServices) {
        final name = service.name.toLowerCase();
        if (name.contains('editor') ||
            name.contains('vscode') ||
            name.contains('intellij') ||
            name.contains('lsp')) {
          editorService = service.name;
          break;
        }
      }

      if (editorService == null) {
        return CallToolResult(
          content: [
            TextContent(
              text: 'No active editor/IDE service is registered in DTD. '
                  'Ensure your IDE is running and connected to DTD.\n'
                  'Registered services: ${registered.clientServices.map((s) => s.name).join(", ")}',
            )
          ],
          isError: true,
        );
      }

      final response = await client.call(editorService, 'getActiveLocation');
      final result = response.result;

      return serializeDualFormat(
        title: 'Active Editor Location Report',
        markdownBody: 'Active editor path and cursor: \n'
            '${const JsonEncoder.withIndent("  ").convert(result)}',
        structuredData: result,
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Failed to get active location: $e')],
        isError: true,
      );
    }
  }

  /// Handles the disconnect tool request.
  Future<CallToolResult> _handleDisconnect(CallToolRequest req) async {
    try {
      await dtdClient?.close();
    } catch (_) {}
    dtdClient = null;
    dtdUri = null;

    if (vmService == null) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Disconnected from DTD. Not connected to any VM Service app.')
        ],
      );
    }
    try {
      unregisterConnectedTools();
    } catch (_) {}

    await cleanupStreams();

    try {
      await vmService!.dispose();
    } catch (e) {
      stderr.writeln('[mcp:connect] Error disposing VM Service: $e');
    }
    vmService = null;
    vmServiceUri = null;
    isolateId = null;
    return CallToolResult(
      content: [TextContent(text: 'Disconnected from Flutter app.')],
    );
  }

  /// Handles the get_app_info tool request.
  Future<CallToolResult> _handleGetAppInfo(CallToolRequest req) async {
    if (vmService == null || isolateId == null) {
      return notConnected();
    }
    final vm = await vmService!.getVM();
    final isolate = await vmService!.getIsolate(isolateId!);

    double fpsVal = 60.0;
    try {
      final fpsResponse = await vmService!.callServiceExtension(
        'ext.flutter.getDisplayRefreshRate',
        isolateId: isolateId,
      );
      fpsVal = (fpsResponse.json?['fps'] as num?)?.toDouble() ?? 60.0;
    } catch (e) {
      stderr.writeln('[mcp:connect] Error getting display refresh rate: $e');
    }

    final extensionRPCs = isolate.extensionRPCs ?? [];
    final flutterExtensions =
        extensionRPCs.where((e) => e.startsWith('ext.flutter.')).toList();
    final includeExtensions = req.arg<bool>('includeExtensions') ?? false;

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
      if (includeExtensions) 'flutterExtensions': flutterExtensions,
      'isolates': (vm.isolates ?? [])
          .map((i) => {
                'id': i.id,
                'name': i.name,
                'isSystem': i.isSystemIsolate ?? false,
              })
          .toList(),
    };

    final md = StringBuffer()
      ..writeln('VM INFORMATION')
      ..writeln('Name: ${vm.name}')
      ..writeln('OS: ${vm.operatingSystem}')
      ..writeln('CPU: ${vm.hostCPU} (target: ${vm.targetCPU})')
      ..writeln('Version: ${vm.version}')
      ..writeln('PID: ${vm.pid}')
      ..writeln()
      ..writeln('APPLICATION INFORMATION')
      ..writeln('Root Library: ${isolate.rootLib?.uri}')
      ..writeln('Library Count: ${isolate.libraries?.length}')
      ..writeln('Pause State: ${isolate.pauseEvent?.kind}')
      ..writeln('Display Refresh Rate: ${fpsVal.toStringAsFixed(1)} Hz')
      ..writeln();

    if (includeExtensions) {
      md
        ..writeln('FLUTTER EXTENSIONS')
        ..writeln(flutterExtensions.isEmpty
            ? 'None'
            : flutterExtensions.map((e) => '- $e').join('\n'))
        ..writeln();
    }

    md
      ..writeln('ISOLATES')
      ..writeln((vm.isolates ?? [])
          .map((i) =>
              '- ${i.name} (${i.id}, system: ${i.isSystemIsolate ?? false})')
          .join('\n'));

    return serializeDualFormat(
      title: 'App Information Details',
      markdownBody: md.toString(),
      structuredData: appInfo,
    );
  }

  /// Handles the discover_apps tool request.
  Future<CallToolResult> _handleAutodiscover(CallToolRequest req) async {
    final workspace = req.arg<String>('workspace_root');
    final autoConnect = req.arg<bool>('autoConnect') ?? true;
    stderr.writeln(
        '[mcp:autodiscover] Starting auto-discovery, workspace=$workspace, autoConnect=$autoConnect');
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
      final reportBuffer = StringBuffer('Discovered Active Apps\n');
      for (final app in runningApps) {
        reportBuffer.writeln('- Project: ${app.projectName}');
        reportBuffer.writeln('  - URI: ${app.serviceUri}');
        reportBuffer.writeln('  - Config Path: ${app.configPath}');
      }
      return CallToolResult(
        content: [TextContent(text: reportBuffer.toString())],
      );
    }

    if (runningApps.length == 1) {
      final app = runningApps.first;
      final arguments = {
        'uri': app.serviceUri,
        if (workspace != null) 'workspace_root': workspace,
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
                  '- Workspace Root: ${workspace ?? "None"}')
        ],
      );
    }

    final report = StringBuffer(
        'Multiple active Flutter applications were discovered. '
        'Please connect explicitly using the connect tool with one of the URIs below:\n\n');
    for (final app in runningApps) {
      report.writeln('- Project: ${app.projectName}');
      report.writeln('  - URI: ${app.serviceUri}');
    }

    return CallToolResult(
      content: [TextContent(text: report.toString())],
    );
  }

  /// Handles the set_response_format tool request.
  Future<CallToolResult> _handleSetResponseFormat(CallToolRequest req) async {
    final fmt = req.requireArg<String>('format');
    if (fmt != 'markdown' && fmt != 'json') {
      return CallToolResult(
        content: [
          TextContent(text: 'Invalid format. Use "markdown" or "json".'),
        ],
        isError: true,
      );
    }
    responseFormat = fmt;
    return CallToolResult(
      content: [TextContent(text: 'Response format set to $fmt.')],
    );
  }
}
