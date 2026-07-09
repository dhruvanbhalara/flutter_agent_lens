import 'package:test/test.dart';
import 'package:dart_mcp/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/mixins/connection_support.dart';
import 'package:flutter_agent_lens/src/mixins/console_logging_support.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';

base class ConnectionLifecycleMock extends MCPServer
    with
        ToolsSupport,
        LoggingSupport,
        RootsTrackingSupport,
        VmConnectionSupport,
        ConsoleLoggingSupport,
        ConnectionSupport {
  ConnectionLifecycleMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  bool _connectedToolsRegistered = false;

  @override
  void registerConnectedTools() {
    if (_connectedToolsRegistered) {
      unregisterConnectedTools();
    }
    registerDtdTools();
    _connectedToolsRegistered = true;
  }

  @override
  void unregisterConnectedTools() {
    if (!_connectedToolsRegistered) return;
    for (final tool in McpTool.values) {
      if (tool.requiresConnection) {
        unregisterTool(tool.name);
      }
    }
    _connectedToolsRegistered = false;
  }
}

void main() {
  late StreamChannelController<String> controller;
  late ConnectionLifecycleMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = ConnectionLifecycleMock(controller.local);
  });

  group('Connection Lifecycle and Tool Registration Tests', () {
    test(
        'registerDtdTools can be called multiple times without throwing duplicate registration exceptions',
        () {
      // First registration should succeed
      expect(() => mock.registerDtdTools(), returnsNormally);

      // Second registration of same tool should also succeed (no duplicate registration error)
      expect(() => mock.registerDtdTools(), returnsNormally);
    });

    test(
        'registerConnectedTools cleanly manages state and unregisters tools when called consecutively',
        () {
      // First registration should succeed
      expect(() => mock.registerConnectedTools(), returnsNormally);

      // Second consecutive registration should succeed cleanly without duplicate key error
      expect(() => mock.registerConnectedTools(), returnsNormally);
    });

    test('unregisterConnectedTools correctly unregisters active tools', () {
      // Register tools
      mock.registerConnectedTools();

      // Disconnect/unregister
      expect(() => mock.unregisterConnectedTools(), returnsNormally);

      // Subsequent call should return early and do nothing
      expect(() => mock.unregisterConnectedTools(), returnsNormally);
    });
  });
}
