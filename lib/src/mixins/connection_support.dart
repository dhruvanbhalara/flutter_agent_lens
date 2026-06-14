import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import 'package:dtd/dtd.dart';
import 'vm_connection_support.dart';
import 'console_logging_support.dart';
import 'dtd_support.dart';
import '../port_discovery.dart';
import '../path_resolver.dart';

base mixin ConnectionSupport
    on
        MCPServer,
        ToolsSupport,
        VmConnectionSupport,
        ConsoleLoggingSupport,
        RootsTrackingSupport {
  void registerConnectionTools() {
    final formatSchema = StringSchema(
      description:
          'Response format: markdown, json, or dual (default: markdown).',
    );

    registerTool(
      Tool(
        name: 'connect',
        description: 'Connect to a running Flutter app via its VM Service URI.',
        inputSchema: ObjectSchema(
          properties: {
            'uri': StringSchema(
              description:
                  'The VM Service HTTP or WS URI (e.g. http://127.0.0.1:8181/auth_token=/).',
            ),
            'vmServiceUri': StringSchema(
              description: 'Alias for the uri parameter.',
            ),
            'workspace_root': StringSchema(
              description:
                  'Absolute path to the local Flutter project root directory.',
            ),
          },
        ),
      ),
      wrapToolCall('connect', _handleConnect, requiresConnection: false),
    );

    registerTool(
      Tool(
        name: 'disconnect',
        description: 'Disconnect from the currently connected Flutter app.',
        inputSchema: emptySchema(),
      ),
      wrapToolCall('disconnect', _handleDisconnect),
    );

    registerTool(
      Tool(
        name: 'get_app_info',
        description:
            'Get detailed information about the connected Flutter app including VM info, isolates, and available extensions.',
        inputSchema: ObjectSchema(
          properties: {
            'includeExtensions': BooleanSchema(
              description:
                  'Whether to include the full list of registered Flutter service extensions (default: false).',
            ),
            'format': formatSchema,
          },
        ),
      ),
      wrapToolCall('get_app_info', _handleGetAppInfo),
    );

    registerTool(
      Tool(
        name: 'discover_apps',
        description:
            'Automatically discover running Flutter apps on this machine.',
        inputSchema: ObjectSchema(
          properties: {
            'autoConnect': BooleanSchema(
              description:
                  'Automatically connect to the first discovered app (default: true).',
            ),
            'workspace_root': StringSchema(
              description:
                  'Absolute path to the local Flutter project root directory.',
            ),
          },
        ),
      ),
      wrapToolCall('discover_apps', _handleAutodiscover,
          requiresConnection: false),
    );
  }

  Future<CallToolResult> _handleConnect(CallToolRequest req) async {
    final rawUri =
        (req.arguments!['uri'] ?? req.arguments!['vmServiceUri']) as String;
    try {
      stderr.writeln('[mcp:connect] Attempting connection to: $rawUri');
      workspaceRoot = req.arguments?['workspace_root'] as String?;

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
        } catch (_) {}
      }

      if (workspaceRoot != null) {
        pathResolver = PathResolver(workspaceRoot!);
      }

      String uriToConnect = rawUri;
      if (isDtdUri(rawUri)) {
        try {
          uriToConnect = await resolveDtdToVmServiceUri(rawUri);
          stderr.writeln(
              '[mcp:connect] DTD resolved VM Service URI: $uriToConnect');

          final self = this;
          if (self is DtdSupport) {
            final dtd = self as DtdSupport;
            try {
              stderr.writeln(
                  '[mcp:connect] Initializing DTD client for DTD URI: $rawUri');
              final parsedDtdUri = Uri.parse(rawUri);
              await dtd.dtdClient?.close();
              dtd.dtdClient = await DartToolingDaemon.connect(parsedDtdUri);
              dtd.dtdUri = rawUri;
              stderr.writeln(
                  '[mcp:connect] DTD client initialized successfully.');
            } catch (dtdErr) {
              stderr.writeln(
                  '[mcp:connect] Failed to initialize DTD client: $dtdErr');
            }
          }
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

      vmService = await vmServiceConnectUri(wsUri);

      final vm = await vmService!.getVM();
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
      isolateId = vm.isolates!.first.id!;
      final ver = await vmService!.getVersion();

      try {
        serviceStreamSub = vmService!.onServiceEvent.listen((Event event) {
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
      } catch (_) {}

      // Clear existing I/O subscriptions and start buffering streams
      startLogging();

      // Enable HTTP timeline logging automatically
      try {
        await vmService!.callServiceExtension(
          'ext.dart.io.httpEnableTimelineLogging',
          isolateId: isolateId,
          args: {'enabled': 'true'},
        );
      } catch (_) {}

      return CallToolResult(
        content: [
          TextContent(
              text: 'Successfully connected to VM Service.\n'
                  '- VM version: ${ver.major}.${ver.minor}\n'
                  '- Main Isolate: ${vm.isolates!.first.name} ($isolateId)\n'
                  '- Workspace Root configured: ${workspaceRoot ?? "None"}')
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

  Future<CallToolResult> _handleDisconnect(CallToolRequest req) async {
    if (vmService == null) {
      return CallToolResult(
        content: [TextContent(text: 'Not connected to any app.')],
      );
    }
    cleanupStreams();

    try {
      await vmService!.dispose();
    } catch (_) {}
    vmService = null;
    vmServiceUri = null;
    isolateId = null;
    return CallToolResult(
      content: [TextContent(text: 'Disconnected from Flutter app.')],
    );
  }

  Future<CallToolResult> _handleGetAppInfo(CallToolRequest req) async {
    final vm = await vmService!.getVM();
    final isolate = await vmService!.getIsolate(isolateId!);

    double fpsVal = 60.0;
    try {
      final fpsResponse = await vmService!.callServiceExtension(
        'ext.flutter.getDisplayRefreshRate',
        isolateId: isolateId,
      );
      fpsVal = (fpsResponse.json?['fps'] as num?)?.toDouble() ?? 60.0;
    } catch (_) {}

    final extensionRPCs = isolate.extensionRPCs ?? [];
    final flutterExtensions =
        extensionRPCs.where((e) => e.startsWith('ext.flutter.')).toList();
    final includeExtensions =
        req.arguments?['includeExtensions'] as bool? ?? false;

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
      format: req.arguments?['format'] as String?,
    );
  }

  Future<CallToolResult> _handleAutodiscover(CallToolRequest req) async {
    final workspace = req.arguments?['workspace_root'] as String?;
    final autoConnect = req.arguments?['autoConnect'] as bool? ?? true;
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
}
