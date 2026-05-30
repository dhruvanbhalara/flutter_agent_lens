import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:flutter_agent_lens/flutter_agent_lens.dart';

void main() async {
  // Bind stdio channel for local process communication
  final server = FlutterAgentLensServer(
    channel: stdioChannel(input: stdin, output: stdout),
  );

  stderr.writeln(
      '[flutter_agent_lens] Server initialized. Listening on Stdio...');
  await server.done;
  exit(0);
}
