import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:dtd/dtd.dart';
import '../enums/mcp_tool.dart';
import 'vm_connection_support.dart';

/// Support mixin providing tools for connecting to and interacting with the
/// Dart Tooling Daemon (DTD) to query IDE status and running VM services.
base mixin DtdSupport on MCPServer, ToolsSupport, VmConnectionSupport {
  /// The active connection to the Dart Tooling Daemon.
  DartToolingDaemon? dtdClient;

  /// The WebSocket URI of the connected Dart Tooling Daemon.
  String? dtdUri;

  /// Registers all DTD-related tools.
  void registerDtdTools() {
    final formatSchema = StringSchema(
      description:
          'Response format: markdown or json (default: markdown).',
    );

    registerTool(
      Tool(
        name: McpTool.connectDtd.name,
        description:
            'Connect to the Dart Tooling Daemon (DTD) to automatically discover running Flutter applications.',
        inputSchema: ObjectSchema(
          properties: {
            'uri': StringSchema(
              description:
                  'The DTD WebSocket URI (e.g. ws://127.0.0.1:59247/em6ZgeqMpvV8tOKg).',
            ),
          },
          required: ['uri'],
        ),
      ),
      wrapToolCall(McpTool.connectDtd, _handleConnectDtd, requiresConnection: false),
    );

    registerTool(
      Tool(
        name: McpTool.getActiveLocation.name,
        description:
            'Get the active editor file path and cursor position when connected via DTD.',
        inputSchema: ObjectSchema(
          properties: {
            'format': formatSchema,
          },
        ),
      ),
      wrapToolCall(McpTool.getActiveLocation, _handleGetActiveLocation,
          requiresConnection: false),
    );
  }

  /// Handles the connect_dtd tool request.
  Future<CallToolResult> _handleConnectDtd(CallToolRequest req) async {
    final uriStr = req.arguments!['uri'] as String;
    try {
      stderr.writeln('[mcp:dtd] Connecting to DTD at: $uriStr');
      final uri = Uri.parse(uriStr);
      final client = await DartToolingDaemon.connect(uri);

      await dtdClient?.close();
      dtdClient = client;
      dtdUri = uriStr;

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
          TextContent(text: 'Not connected to DTD. Run connect_dtd first.')
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
        format: req.arguments?['format'] as String?,
      );
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: 'Failed to get active location: $e')],
        isError: true,
      );
    }
  }
}
