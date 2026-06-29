import 'dart:async';
import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/flutter_agent_lens.dart';
import 'package:mocktail/mocktail.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:vm_service/vm_service.dart';

class MockVmService extends Mock implements VmService {}

/// Helper class to run tool tests against the FlutterAgentLensServer in-process.
class TestServer {
  final MockVmService mockVmService = MockVmService();
  late final FlutterAgentLensServer server;
  late final ServerConnection clientConnection;

  late final StreamController<String> clientToServer;
  late final StreamController<String> serverToClient;

  TestServer() {
    clientToServer = StreamController<String>();
    serverToClient = StreamController<String>();

    final serverChannel = StreamChannel<String>.withCloseGuarantee(
      clientToServer.stream,
      serverToClient.sink,
    );

    final clientChannel = StreamChannel<String>.withCloseGuarantee(
      serverToClient.stream,
      clientToServer.sink,
    );

    server = FlutterAgentLensServer(channel: serverChannel);

    // Create an MCP client to interact with the server
    final client = MCPClient(
      Implementation(name: 'test-client', version: '1.0.0'),
    );
    clientConnection = client.connectServer(clientChannel);
  }

  Future<void> initialize() async {
    final result = await clientConnection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: ClientCapabilities(),
        clientInfo: Implementation(name: 'test-client', version: '1.0.0'),
      ),
    );
    clientConnection.notifyInitialized(InitializedNotification());
  }

  Future<CallToolResult> callTool(String name,
      [Map<String, dynamic>? arguments]) async {
    return await clientConnection.callTool(
      CallToolRequest(name: name, arguments: arguments),
    );
  }

  /// Sets up a connected VM Service state on the server.
  void setConnectedState({
    required String isolateId,
    required VM vm,
    required Isolate isolate,
  }) {
    server.vmService = mockVmService;
    server.isolateId = isolateId;

    when(() => mockVmService.getVM()).thenAnswer((_) async => vm);
    when(() => mockVmService.getIsolate(isolateId))
        .thenAnswer((_) async => isolate);
    when(() => mockVmService.getVersion())
        .thenAnswer((_) async => Version(major: 3, minor: 60));
  }

  Future<void> shutdown() async {
    await clientConnection.shutdown();
    await server.shutdown();
    await clientToServer.close();
    await serverToClient.close();
  }
}
