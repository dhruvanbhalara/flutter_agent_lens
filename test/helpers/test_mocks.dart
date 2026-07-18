import 'dart:async';

import 'package:vm_service/vm_service.dart';

class FakeVmService extends VmService {
  final Map<String, Map<String, dynamic>> serviceExtensionResponses = {};
  final StreamController<Event> _eventController =
      StreamController<Event>.broadcast();

  bool disposeCalled = false;
  int allocationProfileCalls = 0;
  List<String>? timelineFlags;
  bool timelineCleared = false;
  Map<String, dynamic>? lastArgs;
  String? lastExtensionCalled;

  List<String> mockExtensionRPCs = [];
  Map<String, dynamic> mockTimelineResponse = {};

  FakeVmService() : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Stream<Event> get onExtensionEvent => _eventController.stream;

  void emitExtensionEvent(Event event) {
    _eventController.add(event);
  }

  void emitRebuildEvent(Map<String, dynamic> data) {
    _eventController.add(Event(
      kind: 'Extension',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      extensionKind: 'Flutter.RebuiltWidgets',
      extensionData: ExtensionData.parse(data),
    ));
  }

  @override
  Future<Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    lastExtensionCalled = method;
    lastArgs = args;
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
    return AllocationProfile(
      members: [
        ClassHeapStats(
          classRef: ClassRef(id: 'c_1', name: 'MyWidget'),
          bytesCurrent: allocationProfileCalls == 1 ? 1000 : 2500,
          instancesCurrent: allocationProfileCalls == 1 ? 10 : 15,
        )
      ],
      memoryUsage: MemoryUsage(
        heapUsage: 10 * 1024 * 1024,
        heapCapacity: 20 * 1024 * 1024,
        externalUsage: 1 * 1024 * 1024,
      ),
    );
  }

  @override
  Future<Success> setVMTimelineFlags(List<String> recordedStreams) async {
    timelineFlags = recordedStreams;
    return Success();
  }

  @override
  Future<Success> clearVMTimeline() async {
    timelineCleared = true;
    return Success();
  }

  @override
  Future<Timeline> getVMTimeline(
      {int? timeExtentMicros, int? timeOriginMicros}) async {
    return Timeline.parse(mockTimelineResponse) ?? Timeline(traceEvents: []);
  }

  @override
  Future<VM> getVM() async {
    return VM(
      name: 'FakeVM',
      operatingSystem: 'android',
      isolates: [IsolateRef(id: 'isolate_1', name: 'main')],
    );
  }

  @override
  Future<Isolate> getIsolate(String isolateId) async {
    return Isolate(
      id: 'isolate_1',
      name: 'main',
      extensionRPCs: mockExtensionRPCs,
      libraries: [
        LibraryRef(
            id: 'lib_1', name: 'main_lib', uri: 'package:my_app/main.dart'),
        LibraryRef(
          id: 'lib_2',
          name: 'debug_rendering',
          uri: 'package:flutter/src/rendering/debug.dart',
        ),
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
    if (isolateId != 'isolate_1') {
      throw RPCError('getStack', -32000, 'Isolate not found');
    }
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
    await _eventController.close();
    return Success();
  }
}
