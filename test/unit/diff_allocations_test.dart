import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/mixins/memory_debugging_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class MemoryDebuggingMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, MemoryDebuggingSupport {
  final Map<String, Tool> registeredToolsMap = {};

  MemoryDebuggingMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        ) {
    registerMemoryTools();
  }

  @override
  void registerTool(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) handler, {
    bool validateArguments = true,
  }) {
    registeredToolsMap[tool.name] = tool;
    super.registerTool(tool, handler, validateArguments: validateArguments);
  }

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForDiffHeap extends vm_service.VmService {
  final Completer<void> _onDoneCompleter = Completer<void>();
  int _profileCallCount = 0;

  FakeVmServiceForDiffHeap() : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Future<void> get onDone => _onDoneCompleter.future;

  @override
  Future<vm_service.AllocationProfile> getAllocationProfile(
    String isolateId, {
    bool? gc,
    bool? reset,
  }) async {
    _profileCallCount++;
    if (_profileCallCount == 1) {
      return vm_service.AllocationProfile(
        members: [
          vm_service.ClassHeapStats(
            classRef: vm_service.ClassRef(id: 'c1', name: 'ActiveWidget'),
            instancesCurrent: 5,
            bytesCurrent: 512,
          ),
          vm_service.ClassHeapStats(
            classRef: vm_service.ClassRef(id: 'c2', name: 'UnchangedClass'),
            instancesCurrent: 10,
            bytesCurrent: 1024,
          ),
        ],
      );
    } else {
      return vm_service.AllocationProfile(
        members: [
          vm_service.ClassHeapStats(
            classRef: vm_service.ClassRef(id: 'c1', name: 'ActiveWidget'),
            instancesCurrent: 15,
            bytesCurrent: 2048,
          ),
          vm_service.ClassHeapStats(
            classRef: vm_service.ClassRef(id: 'c2', name: 'UnchangedClass'),
            instancesCurrent: 10,
            bytesCurrent: 1024,
          ),
        ],
      );
    }
  }
}

void main() {
  group('MemoryDebuggingSupport filter_zero_deltas Tests', () {
    late MemoryDebuggingMock mockServer;
    late FakeVmServiceForDiffHeap fakeVm;

    setUp(() {
      fakeVm = FakeVmServiceForDiffHeap();
      final controller = StreamChannelController<String>();
      mockServer = MemoryDebuggingMock(controller.foreign);
      mockServer.vmService = fakeVm;
      mockServer.isolateId = 'isolate_1';
    });

    test('memory tool schema contains filter_zero_deltas property', () {
      final tool = mockServer.registeredToolsMap[McpTool.memory.name];
      expect(tool, isNotNull);
      final schemaProps = tool!.inputSchema.properties;
      expect(schemaProps, isNotNull);
      expect(schemaProps!['filter_zero_deltas'], isA<BooleanSchema>());
    });

    test('diff_allocations filters zero deltas when filter_zero_deltas is true',
        () async {
      final req = CallToolRequest(
        name: McpTool.memory.name,
        arguments: {
          'action': 'diff_allocations',
          'duration_seconds': 1,
          'filter_zero_deltas': true,
        },
      );

      final result = await mockServer.callTool(req);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('ActiveWidget'));
      expect(text, isNot(contains('UnchangedClass')));
    });
  });
}
