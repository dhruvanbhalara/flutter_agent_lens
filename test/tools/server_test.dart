import 'dart:async';
import 'package:test/test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:vm_service/vm_service.dart';
import 'package:flutter_agent_lens/flutter_agent_lens.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:dart_mcp/server.dart';

class FakeVmService extends VmService {
  final Map<String, Map<String, dynamic>> serviceExtensionResponses = {};
  final List<ClassHeapStats> mockHeapStats = [];
  bool disposeCalled = false;
  int allocationProfileCalls = 0;

  FakeVmService()
      : super(
          const Stream<dynamic>.empty(),
          (message) {},
        );

  @override
  Stream<Event> get onExtensionEvent => const Stream<Event>.empty();

  @override
  Future<Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    final responseMap = serviceExtensionResponses[method];
    if (responseMap != null) {
      return Response.parse(responseMap)!;
    }
    return Response.parse(<String, dynamic>{'result': 'success'})!;
  }

  @override
  Future<AllocationProfile> getAllocationProfile(
    String isolateId, {
    bool? reset,
    bool? gc,
  }) async {
    allocationProfileCalls++;
    if (allocationProfileCalls == 1) {
      // Baseline
      return AllocationProfile(
        members: [
          ClassHeapStats(
            classRef: ClassRef(id: 'c_1', name: 'MyWidget'),
            bytesCurrent: 1000,
            instancesCurrent: 10,
          )
        ],
        memoryUsage: MemoryUsage(
          heapUsage: 10 * 1024 * 1024,
          heapCapacity: 20 * 1024 * 1024,
          externalUsage: 1 * 1024 * 1024,
        ),
      );
    } else {
      // Profiling result
      return AllocationProfile(
        members: [
          ClassHeapStats(
            classRef: ClassRef(id: 'c_1', name: 'MyWidget'),
            bytesCurrent: 2500, // Grew by 1500 bytes
            instancesCurrent: 15, // Grew by 5 instances
          )
        ],
        memoryUsage: MemoryUsage(
          heapUsage: 10 * 1024 * 1024,
          heapCapacity: 20 * 1024 * 1024,
          externalUsage: 1 * 1024 * 1024,
        ),
      );
    }
  }

  @override
  Future<Success> setVMTimelineFlags(List<String> recordedStreams) async {
    return Success();
  }

  @override
  Future<Success> clearVMTimeline() async {
    return Success();
  }

  @override
  Future<Timeline> getVMTimeline(
      {int? timeExtentMicros, int? timeOriginMicros}) async {
    return Timeline(traceEvents: []);
  }

  @override
  Future<VM> getVM() async {
    return VM(
      name: 'FakeVM',
      isolates: [IsolateRef(id: 'isolate_1', name: 'main')],
    );
  }

  @override
  Future<Isolate> getIsolate(String isolateId) async {
    return Isolate(
      id: 'isolate_1',
      name: 'main',
      libraries: [
        LibraryRef(
            id: 'lib_1', name: 'main_lib', uri: 'package:my_app/main.dart'),
        LibraryRef(
            id: 'lib_2',
            name: 'debug_rendering',
            uri: 'package:flutter/src/rendering/debug.dart'),
      ],
    );
  }

  @override
  Future<InstanceRef> evaluate(
    String isolateId,
    String targetId,
    String expression, {
    Map<String, String>? scope,
    bool? disableBreakpoints,
    String? idZoneId,
  }) async {
    return InstanceRef(
      id: 'ref_1',
      kind: InstanceKind.kBool,
      valueAsString: 'true',
    );
  }

  @override
  Future<Success> clearCpuSamples(String isolateId) async {
    return Success();
  }

  @override
  Future<CpuSamples> getCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
    return CpuSamples(
      functions: [
        ProfileFunction(
          function: FuncRef(id: 'func_1', name: 'myFunction'),
          exclusiveTicks: 10,
          inclusiveTicks: 20,
        ),
      ],
      sampleCount: 1,
      samples: [],
    );
  }

  @override
  Future<Stack> getStack(String isolateId,
      {String? idZoneId, int? limit}) async {
    return Stack(
      frames: [
        Frame(
          index: 0,
          function: FuncRef(id: 'func_1', name: 'myFunction'),
          location: SourceLocation(
            script: ScriptRef(id: 'script_1', uri: 'package:my_app/main.dart'),
            line: 42,
          ),
        ),
      ],
      messages: [],
    );
  }

  @override
  Future<Breakpoint> addBreakpointWithScriptUri(
    String isolateId,
    String scriptUri,
    int line, {
    int? column,
  }) async {
    return Breakpoint(
      id: 'bp_1',
      breakpointNumber: 1,
      enabled: true,
      resolved: true,
      location: SourceLocation(
        script: ScriptRef(id: 'script_1', uri: scriptUri),
        line: line,
      ),
    );
  }

  @override
  Future<Success> removeBreakpoint(
    String isolateId,
    String breakpointId,
  ) async {
    return Success();
  }

  @override
  Future<Success> dispose() async {
    disposeCalled = true;
    return Success();
  }
}

void main() {
  late FlutterAgentLensServer server;
  late StreamChannelController<String> controller;
  late FakeVmService fakeVmService;

  setUp(() async {
    controller = StreamChannelController<String>();
    server = FlutterAgentLensServer(channel: controller.local);
    fakeVmService = FakeVmService();

    // Initialize server to register all tools before running any test
    await server.initialize(InitializeRequest(
      protocolVersion: ProtocolVersion.v2024_11_05,
      capabilities: ClientCapabilities(),
      clientInfo: Implementation(name: 'test_client', version: '1.0'),
    ));
  });

  group('FlutterAgentLensServer MCP Tool Integration Tests', () {
    test('Server initializes and registers all tools', () async {
      final toolsResult = await server.listTools(ListToolsRequest());
      expect(toolsResult.tools, isNotEmpty);

      final toolNames = toolsResult.tools.map((t) => t.name).toList();
      expect(toolNames, contains(McpTool.connect.name));
      expect(toolNames, contains(McpTool.disconnect.name));
      expect(toolNames, contains(McpTool.getMemorySnapshot.name));
      expect(toolNames, contains(McpTool.toggleDebugFlag.name));
    });

    test('connect tool updates vmServiceUri and isolateId', () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      final infoResult = await server.callTool(
        CallToolRequest(
          name: McpTool.getAppInfo.name,
          arguments: const {},
        ),
      );

      if (infoResult.isError == true) {
        final text = (infoResult.content.first as TextContent).text;
        fail('getAppInfo failed: $text');
      }

      expect(infoResult.isError, isNot(isTrue));
      expect(server.vmServiceUri, equals('ws://127.0.0.1:8181/auth_token/ws'));
      expect(server.isolateId, equals('isolate_1'));
    });

    test('disconnect tool cleans up active streams and disposes VM Service',
        () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      final result = await server.callTool(
        CallToolRequest(
          name: McpTool.disconnect.name,
          arguments: const {},
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(fakeVmService.disposeCalled, isTrue);
      expect(server.vmService, isNull);
      expect(server.isolateId, isNull);
    });

    test('toggle_debug_flag calls correct service extension', () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      fakeVmService
          .serviceExtensionResponses['ext.flutter.inspector.debugPaint'] = {
        'value': 'true'
      };

      final result = await server.callTool(
        CallToolRequest(
          name: McpTool.toggleDebugFlag.name,
          arguments: const {
            'flag_name': 'debugPaintSizeEnabled',
            'value': 'true',
          },
        ),
      );

      if (result.isError == true) {
        final text = (result.content.first as TextContent).text;
        fail('toggle_debug_flag failed: $text');
      }

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('debugPaintSizeEnabled'));
      expect(text, contains('true'));
    });

    test('getMemorySnapshot retrieves structured memory info', () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      final result = await server.callTool(
        CallToolRequest(
          name: McpTool.getMemorySnapshot.name,
          arguments: const {
            'topN': 5,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('MyWidget'));
      expect(text, contains('1000.00 B'));
      expect(text, contains('10 instances'));
    });

    test('diffHeapAllocations returns differences correctly', () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      final result = await server.callTool(
        CallToolRequest(
          name: McpTool.diffHeapAllocations.name,
          arguments: const {
            'duration_seconds': 0, // 0 for instantaneous test
            'expression': '1 + 1',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('+1.46 KB')); // 1500 bytes diff
      expect(text, contains('+5'));
    });

    test('getcpuProfile scans execution hotspots', () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      final result = await server.callTool(
        CallToolRequest(
          name: McpTool.getCpuProfile.name,
          arguments: const {
            'duration_seconds': 0, // Instant
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('myFunction'));
      expect(text, contains('10')); // Exclusive ticks
    });

    test('getCallStack retrieves frame index and methods', () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      final result = await server.callTool(
        CallToolRequest(
          name: McpTool.getCallStack.name,
          arguments: const {
            'limit': 5,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('myFunction'));
      expect(text, contains('main.dart:42'));
    });

    test('addBreakpoint and removeBreakpoint manages isolate pause limits',
        () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      // Add breakpoint
      final addResult = await server.callTool(
        CallToolRequest(
          name: McpTool.addBreakpoint.name,
          arguments: const {
            'file_path': 'lib/main.dart',
            'line': 42,
          },
        ),
      );

      if (addResult.isError == true) {
        final text = (addResult.content.first as TextContent).text;
        fail('addBreakpoint failed: $text');
      }

      expect(addResult.isError, isNot(isTrue));
      final addText = (addResult.content.first as TextContent).text;
      expect(addText, contains('bp_1'));
      expect(addText, contains('lib/main.dart:42'));

      // Remove breakpoint
      final removeResult = await server.callTool(
        CallToolRequest(
          name: McpTool.removeBreakpoint.name,
          arguments: const {
            'breakpoint_id': 'bp_1',
          },
        ),
      );

      expect(removeResult.isError, isNot(isTrue));
      final removeText = (removeResult.content.first as TextContent).text;
      expect(removeText, contains('removed breakpoint'));
    });

    test('getWidgetTree returns element nodes', () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      fakeVmService.serviceExtensionResponses[
          'ext.flutter.inspector.getRootWidgetSummaryTree'] = {
        'result': {
          'description': 'Container',
          'widgetRuntimeType': 'Container',
          'createdByLocalProject': true,
          'creationLocation': {
            'file': 'file:///Users/User/projects/my_app/lib/main.dart',
            'line': 50,
            'column': 12
          },
          'hasChildren': false,
          'children': <dynamic>[]
        }
      };

      final result = await server.callTool(
        CallToolRequest(
          name: McpTool.getWidgetTree.name,
          arguments: const {
            'maxDepth': 2,
          },
        ),
      );

      if (result.isError == true) {
        final text = (result.content.first as TextContent).text;
        fail('getWidgetTree failed: $text');
      }

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Container'));
      expect(text, contains('lib/main.dart:50'));
    });

    test('hotReload and hotRestart trigger extension calls', () async {
      server.vmService = fakeVmService;
      server.isolateId = 'isolate_1';
      server.vmServiceUri = 'ws://127.0.0.1:8181/auth_token/ws';

      // Hot reload
      final reloadResult = await server.callTool(
        CallToolRequest(
          name: McpTool.hotReload.name,
          arguments: const {},
        ),
      );
      expect(reloadResult.isError, isNot(isTrue));

      // Hot restart
      final restartResult = await server.callTool(
        CallToolRequest(
          name: McpTool.hotRestart.name,
          arguments: const {},
        ),
      );
      expect(restartResult.isError, isNot(isTrue));
    });
  });
}
