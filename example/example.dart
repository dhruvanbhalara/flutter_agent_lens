import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:flutter_agent_lens/flutter_agent_lens.dart';

/// Starts the Flutter Agent Lens MCP server over stdio.
///
/// Run a Flutter app in debug mode first, then launch this server and connect
/// your MCP client (e.g. Claude Desktop) to it.
///
/// ```bash
/// dart run example/example.dart
/// ```
void main() async {
  final server = FlutterAgentLensServer(
    channel: stdioChannel(input: stdin, output: stdout),
  );
  await server.done;
  exit(0);
}
