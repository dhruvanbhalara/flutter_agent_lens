import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/utils/tool_error_handler.dart';

/// Support mixin providing bidirectional package URI and local file path resolution.
base mixin UriResolutionSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers the resolve_uri tool for resolving URIs and file paths.
  void registerUriResolutionTools() {
    registerTool(
      Tool(
        name: McpTool.resolveUri.name,
        description:
            'Resolve package URIs to local file paths, or local file paths to package URIs.',
        inputSchema: ObjectSchema(
          properties: {
            'uris': ListSchema(
              items: StringSchema(),
              description: 'List of URIs or file paths to resolve.',
            ),
            'direction': StringSchema(
              description:
                  'Direction of resolution: "to_local" (default, package URI -> file path) or "to_package" (file path -> package URI).',
            ),
          },
          required: ['uris'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: true,
        ),
      ),
      handleResolveUri,
    );
  }

  /// Handles the resolve_uri tool execution.
  Future<CallToolResult> handleResolveUri(CallToolRequest req) async {
    return safeToolCall(
      toolName: McpTool.resolveUri.name,
      action: () async {
        final service = vmService;
        final currentIsolateId = isolateId;
        if (service == null || currentIsolateId == null) {
          return notConnected();
        }

        final rawUris = req.arguments?['uris'];
        if (rawUris is! List ||
            rawUris.isEmpty ||
            !rawUris.every((item) => item is String)) {
          return CallToolResult(
            content: [
              TextContent(
                text:
                    'Invalid argument: "uris" must be a non-empty list of strings.',
              ),
            ],
            isError: true,
          );
        }

        final uris = List<String>.from(rawUris);
        final direction = req.arg<String>('direction') ?? 'to_local';

        final response = direction == 'to_package'
            ? await service.lookupPackageUris(currentIsolateId, uris)
            : await service.lookupResolvedPackageUris(currentIsolateId, uris);

        final resolvedUris = response.uris ?? [];
        final results = <String, String?>{};
        final md = StringBuffer();
        md.writeln('### URI Resolution ($direction)\n');
        md.writeln('| Input URI | Resolved URI |');
        md.writeln('| :--- | :--- |');

        for (var i = 0; i < uris.length; i++) {
          final uri = uris[i];
          final resolved = i < resolvedUris.length ? resolvedUris[i] : null;
          results[uri] = resolved;
          final displayResolved =
              resolved != null ? '`$resolved`' : '*(unresolved)*';
          md.writeln('| `$uri` | $displayResolved |');
        }

        return serializeDualFormat(
          req: req,
          title: 'URI Resolution ($direction)',
          markdownBody: md.toString().trim(),
          structuredData: {
            'direction': direction,
            'results': results,
          },
        );
      },
    );
  }
}
