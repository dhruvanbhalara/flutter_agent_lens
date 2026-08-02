import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/extensions/vm_service_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/models/memory_models.dart';
import 'package:flutter_agent_lens/src/utils/safe_sampling_window.dart';
import 'package:vm_service/vm_service.dart';

/// Support mixin providing tools for analyzing heap usage, tracking class instances,
/// and capturing and comparing memory snapshots.
base mixin MemoryDebuggingSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Named cache of taken memory snapshots.
  final Map<String, MemorySnapshot> memorySnapshots = {};

  /// Subscription to the VM Service's GC event stream.
  StreamSubscription<Event>? _gcStreamSub;

  /// Ring buffer of collected GC events (max 500).
  final List<Map<String, dynamic>> _gcEventBuffer = [];

  /// Whether GC stream monitoring is currently active.
  bool _gcStreamActive = false;

  /// Timestamp in milliseconds when GC stream monitoring started.
  int? _gcStreamStartTime;

  /// Registers all memory debugging and profiling tools.
  void registerMemoryTools() {
    registerTool(
      Tool(
        name: McpTool.memory.name,
        description:
            'Manage memory snapshots, heap diffs, class memory audits, retaining path traces, '
            'GC triggers, GC streams, memory timelines, and memory explanations. '
            'Actions: get_snapshot (heap overview), save (named snapshot), compare (diff two snapshots), '
            'list (show saved), audit_leak (inspect class instances), diff_allocations (delta heap over time), '
            'get_referrers (trace object retaining path), force_gc (trigger GC & report freed memory), '
            'start_gc_stream (subscribe to GC events), stop_gc_stream (end GC subscription & get events), '
            'get_memory_timeline (record RSS/heap/GC over duration), watch_gc_pressure (monitor GC frequency), '
            'explain_memory_breakdown (plain English RSS/heap/external/raster overview).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description:
                  'The memory action: get_snapshot, save, compare, list, audit_leak, diff_allocations, '
                  'get_referrers, force_gc, start_gc_stream, stop_gc_stream, get_memory_timeline, '
                  'watch_gc_pressure, explain_memory_breakdown.',
            ),
            'name': StringSchema(description: 'Snapshot name (for save).'),
            'before':
                StringSchema(description: 'Before snapshot (for compare).'),
            'after': StringSchema(description: 'After snapshot (for compare).'),
            'forceGC': BooleanSchema(
                description:
                    'Force GC before action (default: false for get_snapshot, true for diff_allocations).'),
            'topN': IntegerSchema(description: 'Top N classes (default: 20).'),
            'class_name': StringSchema(
              description:
                  'Name of the class to inspect (required for audit_leak, e.g. _MyHomePageState).',
            ),
            'limit': limitSchema(defaultValue: 100),
            'durationSeconds': durationSchema(),
            'expression': StringSchema(
              description:
                  'Optional expression to execute during diff_allocations.',
            ),
            'object_id': StringSchema(
              description:
                  'The VM ID of the object to trace (required for get_referrers).',
            ),
            'includeRawResponse': BooleanSchema(
              description:
                  'Whether to include the raw response in structured data (for get_referrers).',
            ),
          },
          required: ['action'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
        ),
      ),
      _handleMemory,
    );
  }

  /// Disposes and clears all saved memory snapshots and stream subscriptions.
  void cleanupMemoryDebugging() {
    memorySnapshots.clear();
    unawaited(_gcStreamSub?.cancel());
    _gcStreamSub = null;
    _gcEventBuffer.clear();
    _gcStreamActive = false;
    _gcStreamStartTime = null;
    _gcStreamRefCount = 0;
  }

  /// Helper to fetch heap usage stats from [AllocationProfile].
  Future<({int heapUsage, int heapCapacity, int externalUsage})> _getHeapStats({
    bool gc = false,
  }) async {
    final profile = await vmService!.getAllocationProfile(isolateId!, gc: gc);
    return (
      heapUsage: profile.memoryUsage?.heapUsage ?? 0,
      heapCapacity: profile.memoryUsage?.heapCapacity ?? 0,
      externalUsage: profile.memoryUsage?.externalUsage ?? 0,
    );
  }

  /// Helper to fetch total RSS process memory in bytes.
  Future<int> _getRssBytes() async {
    try {
      final usage = await vmService!.getProcessMemoryUsage();
      return usage.root?.size ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Reference counter for active GC stream observers.
  int _gcStreamRefCount = 0;

  /// Ensures GC stream subscription is active with reference counting.
  Future<void> _ensureGcStream() async {
    _gcStreamRefCount++;
    if (_gcStreamActive) return;

    if (vmService != null) {
      try {
        await vmService!.streamListen(EventStreams.kGC);
      } on RPCError catch (e) {
        if (e.code != 103) rethrow;
      }
    }
    await _gcStreamSub?.cancel();
    _gcStreamSub = vmService!.onGCEvent.listen((Event event) {
      final item = <String, dynamic>{
        'kind': event.kind ?? 'GC',
        'timestamp': event.timestamp ?? DateTime.now().millisecondsSinceEpoch,
        if (event.gcType != null) 'gcType': event.gcType,
      };
      if (event.json != null) {
        final raw = event.json!;
        if (raw.containsKey('reason')) item['reason'] = raw['reason'];
        if (raw.containsKey('duration')) item['duration'] = raw['duration'];
      }
      _gcEventBuffer.add(item);
      if (_gcEventBuffer.length > 500) {
        _gcEventBuffer.removeAt(0);
      }
    });
    _gcStreamActive = true;
    _gcStreamStartTime = DateTime.now().millisecondsSinceEpoch;
  }

  /// Internal cleanup for GC event stream with reference counting.
  Future<void> _stopGcStreamInternal({bool force = false}) async {
    if (!force && _gcStreamRefCount > 1) {
      _gcStreamRefCount--;
      return;
    }
    _gcStreamRefCount = 0;
    await _gcStreamSub?.cancel();
    _gcStreamSub = null;
    _gcStreamActive = false;
    if (vmService != null) {
      try {
        await vmService!.streamCancel(EventStreams.kGC);
      } catch (e) {
        stderr.writeln('[mcp:memory] Error cancelling GC stream: $e');
      }
    }
  }

  Future<CallToolResult> _handleAuditClassMemoryLeak(
      CallToolRequest req) async {
    final className = req.requireArg<String>('class_name');
    final limit = req.intArg('limit', defaultValue: 100)!;
    stderr.writeln(
        '[mcp:audit_memory] Auditing class: $className (limit=$limit)');

    final classList = await vmService!.getClassList(isolateId!);
    final classes = classList.classes ?? [];
    ClassRef? classRef;
    for (final c in classes) {
      if (c.name == className) {
        classRef = c;
        break;
      }
    }

    if (classRef == null || classRef.id == null) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'Class $className not found in target isolate.',
          ),
        ],
        isError: true,
      );
    }

    final instancesResponse =
        await vmService!.getInstances(isolateId!, classRef.id!, limit);
    final instances = instancesResponse.instances ?? [];

    final reports = <Map<String, dynamic>>[];
    final mdBuffer = StringBuffer();

    final mountedResults = await Future.wait(
      instances.map((instanceRef) async {
        final instanceId = instanceRef.id;
        if (instanceId == null) {
          return (instanceId: null, isMounted: true);
        }
        try {
          final evalResult = await vmService!.evaluate(
            isolateId!,
            instanceId,
            'this.mounted',
          );
          final isMounted =
              evalResult is InstanceRef && evalResult.valueAsString == 'true';
          return (instanceId: instanceId, isMounted: isMounted);
        } catch (_) {
          return (instanceId: instanceId, isMounted: true);
        }
      }),
    );

    final unmountedInstances = mountedResults
        .where((r) => r.instanceId != null && !r.isMounted)
        .map((r) => r.instanceId!)
        .toList();

    if (unmountedInstances.isNotEmpty) {
      final retainingPathResults = await _batchAsync(
        unmountedInstances,
        (instanceId) async {
          try {
            final retainingPath =
                await vmService!.getRetainingPath(isolateId!, instanceId, 15);
            final pathElements = <String>[];
            final elements = retainingPath.elements ?? [];
            for (final element in elements.whereType<RetainingObject>()) {
              final val = element.value;
              if (val is InstanceRef) {
                pathElements.add('${val.classRef?.name} (${val.id})');
              } else {
                pathElements.add(val.toString());
              }
            }
            return {
              'instance_id': instanceId,
              'mounted': false,
              'retaining_path': pathElements,
            };
          } catch (e) {
            return {
              'instance_id': instanceId,
              'mounted': false,
              'retaining_path': ['Error retrieving retaining path: $e'],
            };
          }
        },
      );
      reports.addAll(retainingPathResults);
    }

    if (reports.isEmpty) {
      mdBuffer.writeln(
          'No memory leaks detected for class `$className`. All heap instances are active.');
    } else {
      mdBuffer.writeln(
          'Warning: Detected ${reports.length} leaked instances for `$className`!');
      for (var i = 0; i < reports.length; i++) {
        mdBuffer.writeln(
            '\n#### Leaked Instance #${i + 1} (${reports[i]['instance_id']})');
        mdBuffer.writeln(
            '- Disposed State: mounted == false but retained in memory.');
        mdBuffer.writeln('- Retention Path:');
        for (final node in reports[i]['retaining_path'] as List<String>) {
          mdBuffer.writeln('  - $node');
        }
      }
    }

    return serializeDualFormat(
      title: 'Memory Leak Audit: $className',
      markdownBody: mdBuffer.toString(),
      structuredData: {
        'class_name': className,
        'total_instances': instances.length,
        'instances': instances.map((i) => i.id).whereType<String>().toList(),
        'leaked_count': reports.length,
        'leaks': reports,
      },
    );
  }

  static const Set<String> _vmInternalClasses = {
    '_OneByteString',
    '_TwoByteString',
    'String',
    '_List',
    '_GrowableList',
    '_ImmutableList',
    '_Mint',
    '_Double',
    'bool',
    'Null',
    'int',
    'double',
    'Class',
    'ForwardingCorpse',
    'FreeListElement',
    'TypeParameter',
    'UnlinkedCall',
    'ICData',
    'Field',
    'Function',
    'Code',
    'Instructions',
    'ObjectPool',
    'PcDescriptors',
    'CodeSourceMap',
    'CompressedStackMaps',
    'Type',
    '_Type',
    'LibraryPrefix',
    '_FunctionType',
    'Namespace',
    'Library',
    'TypeArguments',
    'ClosureData',
    'SubtypeTestCache',
    'SingleTargetCache',
    'MegamorphicCache',
    'WeakProperty',
    'WeakReference',
    'FinalizerEntry',
    '_WeakProperty',
    '_WeakReference',
    'KernelProgramInfo',
    'Script',
    'Bytecode',
    '_Int8List',
    '_Uint8List',
    '_Uint16List',
    '_Uint32List',
    '_Int32List',
    '_Float32List',
    '_Float64List',
    '_ExternalOneByteString',
    'Array',
    'GrowableObjectArray',
    'Context',
    'ContextScope',
    'RegExp',
    '_RegExp',
    'LocalVarDescriptors',
    'ExceptionHandlers',
    'ParameterTypeCheck',
    'ApiErrorClass',
    'LanguageError',
    'Bool',
    'Sentinel',
    'FfiTrampolineData',
  };

  bool _isVmInternal(String name) {
    return _vmInternalClasses.contains(name);
  }

  /// Handles the diff_heap_allocations tool request.
  Future<CallToolResult> _handleDiffHeapAllocations(CallToolRequest req) async {
    final duration = req.intArg('durationSeconds', defaultValue: 3)!;
    final expression = req.arg<String>('expression');
    final forceGc = req.arg<bool>('forceGC') ?? true;

    stderr.writeln(
        '[mcp:diff_heap] Starting heap profiling (duration=${duration}s, forceGc=$forceGc)');

    final baselineProfile =
        await vmService!.getAllocationProfile(isolateId!, gc: forceGc);
    final baselineStats = <String, ClassHeapStats>{};
    final baselineMembers =
        (baselineProfile.members ?? const []).cast<ClassHeapStats>();
    for (final ClassHeapStats member in baselineMembers) {
      final className = member.classRef?.name;
      if (className != null && className.isNotEmpty) {
        baselineStats[className] = member;
      }
    }

    if (expression != null && expression.isNotEmpty) {
      stderr
          .writeln('[mcp:diff_heap] Evaluating action expression: $expression');
      final libraryId = await getEvaluationLibraryId();
      await vmService!.evalSafe(isolateId!, libraryId, expression);
    }

    stderr.writeln('[mcp:diff_heap] Sampling memory for ${duration}s...');
    final sampleResult = await safeSamplingWindow(
      vmService: vmService,
      duration: Duration(seconds: duration),
    );

    AllocationProfile? currentProfile;
    if (sampleResult.completed) {
      try {
        currentProfile = await vmService
            ?.getAllocationProfile(isolateId!, gc: false)
            .timeout(const Duration(seconds: 1));
      } catch (e) {
        stderr.writeln(
            '[mcp:diff_heap] Error fetching second allocation profile: $e');
      }
    }

    final deltas = <Map<String, dynamic>>[];
    final currentMembers =
        (currentProfile?.members ?? const []).cast<ClassHeapStats>();

    for (final ClassHeapStats member in currentMembers) {
      final className = member.classRef?.name;
      if (className == null) continue;

      final baseline = baselineStats[className];
      final baselineInstances = baseline?.instancesCurrent ?? 0;
      final baselineBytes = baseline?.bytesCurrent ?? 0;

      final currentInstances = member.instancesCurrent ?? 0;
      final currentBytes = member.bytesCurrent ?? 0;

      final instanceDelta = currentInstances - baselineInstances;
      final bytesDelta = currentBytes - baselineBytes;

      if (instanceDelta != 0 || bytesDelta != 0) {
        // Filter out VM-internal noise if delta is tiny
        if (_isVmInternal(className) &&
            instanceDelta.abs() <= 1 &&
            bytesDelta.abs() < 512) {
          continue;
        }
        deltas.add({
          'class': className,
          'instances_before': baselineInstances,
          'instances_after': currentInstances,
          'instances_delta': instanceDelta,
          'bytes_before': baselineBytes,
          'bytes_after': currentBytes,
          'bytes_delta': bytesDelta,
        });
      }
    }

    final limit = req.intArg('limit', defaultValue: 20)!;
    _sortDeltas(deltas, 'instances_delta', 'bytes_delta');

    final md = StringBuffer();
    sampleResult.writeWarningIfInterrupted(
      md,
      requestedSeconds: duration,
      dataName: 'baseline snapshot captured before disconnect',
    );
    md
      ..writeln('Memory Allocations Delta\n')
      ..write(_formatAllocationDiffTable(deltas));

    return serializeDualFormat(
      title: 'Memory Delta Analysis',
      markdownBody: md.toString(),
      structuredData: {
        'duration_seconds': duration,
        'expression_run': expression,
        'force_gc': forceGc,
        'deltas': deltas.take(limit).toList(),
      },
    );
  }

  /// Handles the get_object_referrers tool request.
  Future<CallToolResult> _handleGetObjectReferrers(CallToolRequest req) async {
    final objectId = req.requireArg<String>('object_id');
    final limit = req.intArg('limit', defaultValue: 15)!;
    final includeRawResponse = req.arg<bool>('includeRawResponse') ?? false;
    stderr.writeln(
        '[mcp:get_referrers] Checking referrers for object_id=$objectId, limit=$limit');

    final retainingPath =
        await vmService!.getRetainingPath(isolateId!, objectId, limit);
    final pathElements = <String>[];

    final elements = retainingPath.elements ?? [];
    for (final element in elements.whereType<RetainingObject>()) {
      final val = element.value;
      if (val is InstanceRef) {
        pathElements.add('${val.classRef?.name} (${val.id})');
      } else {
        pathElements.add(val.toString());
      }
    }

    final md = StringBuffer('Retaining Path for Object: $objectId\n\n');
    if (pathElements.isEmpty) {
      md.writeln(
          'No retaining path returned. The object might have been garbage collected or is a root.');
    } else {
      md.writeln(
          'The following references are keeping this object alive in the heap:');
      md.writeln();
      for (var i = 0; i < pathElements.length; i++) {
        md.writeln('${i + 1}. ${pathElements[i]}');
      }
    }

    return serializeDualFormat(
      title: 'Retaining Path / Leak Trace Report',
      markdownBody: md.toString(),
      structuredData: {
        'object_id': objectId,
        'path_length': pathElements.length,
        'retaining_path': pathElements,
        if (includeRawResponse) 'raw_response': retainingPath.json,
      },
    );
  }

  /// Handles the save_snapshot tool request.
  Future<CallToolResult> _handleSaveSnapshot(CallToolRequest req) async {
    final name = req.requireArg<String>('name');
    final forceGc = req.arg<bool>('forceGC') ?? true;
    final maxSnapshots = req.intArg('limit', defaultValue: 10)!;

    final snapshot = await _takeSnapshot(name, forceGc);
    while (
        memorySnapshots.length >= maxSnapshots && memorySnapshots.isNotEmpty) {
      final oldestKey = memorySnapshots.keys.first;
      memorySnapshots.remove(oldestKey);
    }
    memorySnapshots[name] = snapshot;

    final lines = [
      'Snapshot "$name" saved.',
      '',
      'Heap: ${formatBytes(snapshot.heapUsage)} / ${formatBytes(snapshot.heapCapacity)}',
      'Classes tracked: ${snapshot.topClasses.length}',
      'Time: ${DateTime.fromMillisecondsSinceEpoch(snapshot.timestamp).toLocal().toString().split(" ").last.split(".").first}',
      '',
      'Saved snapshots: ${memorySnapshots.keys.join(", ")}',
    ];

    return CallToolResult(
      content: [TextContent(text: lines.join('\n'))],
    );
  }

  /// Handles the compare_snapshots tool request.
  Future<CallToolResult> _handleCompareSnapshots(CallToolRequest req) async {
    final before = req.requireArg<String>('before');
    final after = req.requireArg<String>('after');

    final snap1 = memorySnapshots[before];
    final snap2 = memorySnapshots[after];

    if (snap1 == null) {
      final available = memorySnapshots.keys.isEmpty
          ? 'none'
          : memorySnapshots.keys.join(', ');
      return CallToolResult(
        content: [
          TextContent(
              text: 'Snapshot "$before" not found. Available: $available')
        ],
        isError: true,
      );
    }

    if (snap2 == null) {
      final available = memorySnapshots.keys.isEmpty
          ? 'none'
          : memorySnapshots.keys.join(', ');
      return CallToolResult(
        content: [
          TextContent(
              text: 'Snapshot "$after" not found. Available: $available')
        ],
        isError: true,
      );
    }

    final heapDiff = snap2.heapUsage - snap1.heapUsage;
    final capacityDiff = snap2.heapCapacity - snap1.heapCapacity;

    final beforeMap = {for (final c in snap1.topClasses) c.name: c};
    final afterMap = {for (final c in snap2.topClasses) c.name: c};

    final allClassNames = <String>{...beforeMap.keys, ...afterMap.keys};
    final diffs = <Map<String, dynamic>>[];

    for (final name in allClassNames) {
      final b = beforeMap[name];
      final a = afterMap[name];
      final bBytes = b?.bytes ?? 0;
      final aBytes = a?.bytes ?? 0;
      final bInstances = b?.instances ?? 0;
      final aInstances = a?.instances ?? 0;

      diffs.add({
        'name': name,
        'bytesBefore': bBytes,
        'bytesAfter': aBytes,
        'bytesDiff': aBytes - bBytes,
        'instancesBefore': bInstances,
        'instancesAfter': aInstances,
        'instancesDiff': aInstances - bInstances,
      });
    }

    final grew = diffs.where((d) => (d['bytesDiff'] as int) > 0).toList();
    _sortDeltas(grew, 'instancesDiff', 'bytesDiff');

    final shrank = diffs.where((d) => (d['bytesDiff'] as int) < 0).toList();
    _sortDeltas(shrank, 'instancesDiff', 'bytesDiff');

    final heapIcon = heapDiff <= 0
        ? '[OK]'
        : heapDiff > 10000000
            ? '[WARNING]'
            : '[INFO]';
    final timeDiffS =
        ((snap2.timestamp - snap1.timestamp) / 1000).toStringAsFixed(1);

    final md = StringBuffer();
    md.writeln('SNAPSHOT COMPARISON: "$before" -> "$after"');
    md.writeln();
    md.writeln('HEAP OVERVIEW');
    md.writeln(
        '$heapIcon Heap usage: ${formatBytes(snap1.heapUsage)} -> ${formatBytes(snap2.heapUsage)} (${heapDiff <= 0 ? "" : "+"}${formatBytes(heapDiff)}, ${_pctChange(snap1.heapUsage, snap2.heapUsage)})');
    md.writeln(
        'Capacity: ${formatBytes(snap1.heapCapacity)} -> ${formatBytes(snap2.heapCapacity)} (${capacityDiff <= 0 ? "" : "+"}${formatBytes(capacityDiff)})');
    md.writeln('Time between snapshots: ${timeDiffS}s');

    final topN = req.intArg('topN', defaultValue: 10)!;

    if (grew.isNotEmpty) {
      md.writeln();
      md.writeln('GREW (top $topN)');
      for (final d in grew.take(topN)) {
        final instDiffVal = d['instancesDiff'] as int;
        final instDiff = instDiffVal > 0 ? '+$instDiffVal' : '$instDiffVal';
        md.writeln(
            '+${formatBytes(d['bytesDiff'] as int)} | $instDiff inst | ${d['name']}');
      }
    }

    if (shrank.isNotEmpty) {
      md.writeln();
      md.writeln('SHRANK (top $topN)');
      for (final d in shrank.take(topN)) {
        final instDiffVal = d['instancesDiff'] as int;
        final instDiff = instDiffVal > 0 ? '+$instDiffVal' : '$instDiffVal';
        md.writeln(
            '-${formatBytes((d['bytesDiff'] as int).abs())} | $instDiff inst | ${d['name']}');
      }
    }

    md.writeln();
    md.writeln('VERDICT');
    final verdict = switch (heapDiff) {
      < -1000000 =>
        'Memory improved by ${formatBytes(heapDiff.abs())} (${_pctChange(snap1.heapUsage, snap2.heapUsage)}).',
      > 1000000 =>
        'Warning: Memory increased by ${formatBytes(heapDiff)} (${_pctChange(snap1.heapUsage, snap2.heapUsage)}). Check the classes that grew above.',
      _ => 'No significant change in memory usage between snapshots.',
    };
    md.writeln(verdict);

    return serializeDualFormat(
      title: 'Snapshot Comparison: "$before" -> "$after"',
      markdownBody: md.toString(),
      structuredData: {
        'before': before,
        'after': after,
        'heap_diff_bytes': heapDiff,
        'heap_pct_change': _pctChange(snap1.heapUsage, snap2.heapUsage),
        'time_diff_seconds': double.tryParse(timeDiffS) ?? 0.0,
        'grew': grew.take(topN).toList(),
        'shrank': shrank.take(topN).toList(),
      },
    );
  }

  /// Handles the list_snapshots tool request.
  Future<CallToolResult> _handleListSnapshots(CallToolRequest req) async {
    if (memorySnapshots.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'No snapshots saved yet. Use `save_snapshot` to create one.')
        ],
      );
    }

    final lines = ['Saved snapshots:', ''];
    memorySnapshots.forEach((name, snap) {
      final timeStr = DateTime.fromMillisecondsSinceEpoch(snap.timestamp)
          .toLocal()
          .toString()
          .split(' ')
          .last
          .split('.')
          .first;
      lines.add('- "$name" - ${formatBytes(snap.heapUsage)} heap, $timeStr');
    });

    return CallToolResult(
      content: [TextContent(text: lines.join('\n'))],
    );
  }

  /// Helper to capture a new [MemorySnapshot] from the VM.
  Future<MemorySnapshot> _takeSnapshot(String name, bool gc) async {
    final profile = await vmService!.getAllocationProfile(isolateId!, gc: gc);
    final heapUsage = profile.memoryUsage?.heapUsage ?? 0;
    final heapCapacity = profile.memoryUsage?.heapCapacity ?? 0;
    final externalUsage = profile.memoryUsage?.externalUsage ?? 0;

    final members = profile.members ?? [];
    final validMembers =
        members.where((m) => m.classRef?.name != null).toList();

    validMembers
        .sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));
    final sorted =
        validMembers.where((m) => (m.bytesCurrent ?? 0) > 0).take(50).toList();

    final topClasses = sorted
        .map((m) => ClassAllocation(
              name: m.classRef?.name ?? 'Unknown',
              bytes: m.bytesCurrent ?? 0,
              instances: m.instancesCurrent ?? 0,
            ))
        .toList();

    return MemorySnapshot(
      name: name,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      heapUsage: heapUsage,
      heapCapacity: heapCapacity,
      externalUsage: externalUsage,
      topClasses: topClasses,
    );
  }

  /// Formats the percentage difference between before and after values.
  String _pctChange(int before, int after) {
    if (before == 0) return after > 0 ? '+inf%' : '0%';
    final pct = ((after - before) / before) * 100;
    final sign = pct > 0 ? '+' : '';
    return '$sign${pct.toStringAsFixed(1)}%';
  }

  /// Handles the get_memory_snapshot tool request.
  Future<CallToolResult> _handleGetMemorySnapshot(CallToolRequest req) async {
    final forceGc = req.arg<bool>('forceGC') ?? false;
    final topN = req.intArg('topN', defaultValue: 20)!;

    stderr.writeln(
        '[mcp:memory_snapshot] Fetching memory snapshot (forceGc=$forceGc, topN=$topN)');

    final profile =
        await vmService!.getAllocationProfile(isolateId!, gc: forceGc);
    final heapUsage = profile.memoryUsage?.heapUsage ?? 0;
    final heapCapacity = profile.memoryUsage?.heapCapacity ?? 0;
    final externalUsage = profile.memoryUsage?.externalUsage ?? 0;
    final heapUtilization =
        heapCapacity > 0 ? (heapUsage / heapCapacity) * 100 : 0.0;

    final members = profile.members ?? [];
    final validMembers =
        members.where((m) => m.classRef?.name != null).toList();

    final sortedBySize = List<ClassHeapStats>.from(validMembers)
      ..sort((a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0));
    final sortedBySizeFiltered =
        sortedBySize.where((m) => (m.bytesCurrent ?? 0) > 0).toList();

    final sortedByInstances = List<ClassHeapStats>.from(validMembers)
      ..sort((a, b) =>
          (b.instancesCurrent ?? 0).compareTo(a.instancesCurrent ?? 0));
    final sortedByInstancesFiltered =
        sortedByInstances.where((m) => (m.instancesCurrent ?? 0) > 0).toList();

    final output = [
      'MEMORY SNAPSHOT',
      '',
      'HEAP OVERVIEW',
      'Heap used: ${formatBytes(heapUsage)}',
      'Heap capacity: ${formatBytes(heapCapacity)}',
      'Utilization: ${heapUtilization.toStringAsFixed(1)}%',
      'External: ${formatBytes(externalUsage)}',
      'Total: ${formatBytes(heapUsage + externalUsage)}',
      if (forceGc) '(Snapshot taken after forced GC)',
      '',
      'TOP $topN CLASSES BY MEMORY',
    ];

    for (final member in sortedBySizeFiltered.take(topN)) {
      final bytesCurrent = member.bytesCurrent ?? 0;
      final instancesCurrent = member.instancesCurrent ?? 0;
      final className = member.classRef?.name ?? 'Unknown';
      final pct = heapUsage > 0
          ? ((bytesCurrent / heapUsage) * 100).toStringAsFixed(1)
          : '0.0';
      output.add(
          '${formatBytes(bytesCurrent)} ($pct%) | $instancesCurrent instances | $className');
    }

    output.add('');
    output.add('TOP 10 CLASSES BY INSTANCE COUNT');

    for (final member in sortedByInstancesFiltered.take(10)) {
      final bytesCurrent = member.bytesCurrent ?? 0;
      final instancesCurrent = member.instancesCurrent ?? 0;
      final className = member.classRef?.name ?? 'Unknown';
      output.add(
          '$instancesCurrent instances | ${formatBytes(bytesCurrent)} | $className');
    }

    final appClasses = sortedByInstancesFiltered
        .where((m) => !_isVmInternal(m.classRef?.name ?? ''))
        .toList();

    if (appClasses.isNotEmpty) {
      output.add('');
      output.add('APP & FRAMEWORK CLASSES');
      for (final cls in appClasses.take(20)) {
        final bytesCurrent = cls.bytesCurrent ?? 0;
        final instancesCurrent = cls.instancesCurrent ?? 0;
        final className = cls.classRef?.name ?? 'Unknown';
        output.add(
            '$instancesCurrent instances | ${formatBytes(bytesCurrent)} | $className');
      }
    }

    final suspiciousClasses =
        appClasses.where((m) => (m.instancesCurrent ?? 0) > 500).toList();

    if (suspiciousClasses.isNotEmpty) {
      output.add('');
      output.add('POTENTIAL CONCERNS');
      for (final cls in suspiciousClasses.take(5)) {
        final bytesCurrent = cls.bytesCurrent ?? 0;
        final instancesCurrent = cls.instancesCurrent ?? 0;
        final className = cls.classRef?.name ?? 'Unknown';
        output.add(
            '- $className: $instancesCurrent instances (${formatBytes(bytesCurrent)}) - check for leaks or excessive allocations');
      }
    }

    if (heapUtilization > 85.0) {
      output.add('');
      output.add(
          'WARNING: Heap utilization above 85%. The app may be at risk of OOM. Consider reducing memory footprint.');
    }

    final structuredData = {
      'heapUsage': heapUsage,
      'heapCapacity': heapCapacity,
      'externalUsage': externalUsage,
      'heapUtilization': heapUtilization,
      'top_classes': sortedBySizeFiltered
          .take(topN)
          .map((m) => {
                'class': m.classRef?.name ?? 'Unknown',
                'bytes': m.bytesCurrent ?? 0,
                'instances': m.instancesCurrent ?? 0,
              })
          .toList(),
      'top_instances': sortedByInstancesFiltered
          .take(10)
          .map((m) => {
                'class': m.classRef?.name ?? 'Unknown',
                'bytes': m.bytesCurrent ?? 0,
                'instances': m.instancesCurrent ?? 0,
              })
          .toList(),
      'app_classes': appClasses
          .take(20)
          .map((m) => {
                'class': m.classRef?.name ?? 'Unknown',
                'bytes': m.bytesCurrent ?? 0,
                'instances': m.instancesCurrent ?? 0,
              })
          .toList(),
    };

    return serializeDualFormat(
      title: 'Memory Snapshot Summary',
      markdownBody: output.join('\n'),
      structuredData: structuredData,
    );
  }

  /// Helper to sort class heap stat deltas by instance delta and byte delta.
  void _sortDeltas(List<Map<String, dynamic>> deltas, String instDeltaKey,
      String bytesDeltaKey) {
    deltas.sort((a, b) {
      final cmp = (b[instDeltaKey] as int)
          .abs()
          .compareTo((a[instDeltaKey] as int).abs());
      if (cmp != 0) return cmp;
      return (b[bytesDeltaKey] as int)
          .abs()
          .compareTo((a[bytesDeltaKey] as int).abs());
    });
  }

  /// Formats allocation difference deltas as a Markdown table.
  String _formatAllocationDiffTable(List<Map<String, dynamic>> deltas,
      {int limit = 20}) {
    if (deltas.isEmpty) {
      return 'No heap allocation changes recorded during the profiling window.\n';
    }
    final md = StringBuffer();
    md.writeln(
        '| Class | Instances Delta | Bytes Delta | Before (Count / Size) | After (Count / Size) |');
    md.writeln('| :--- | :--- | :--- | :--- | :--- |');
    for (final d in deltas.take(limit)) {
      final instDelta = d['instances_delta'] as int;
      final bytesDelta = d['bytes_delta'] as int;
      final instDeltaStr = instDelta > 0 ? '+$instDelta' : '$instDelta';
      final byteDeltaStr = bytesDelta > 0
          ? '+${formatBytes(bytesDelta)}'
          : formatBytes(bytesDelta);

      md.writeln(
        '| ${d['class']} | $instDeltaStr | $byteDeltaStr | '
        '${d['instances_before']} / ${formatBytes(d['bytes_before'] as int)} | '
        '${d['instances_after']} / ${formatBytes(d['bytes_after'] as int)} |',
      );
    }
    if (deltas.length > limit) {
      md.writeln('\n_...and ${deltas.length - limit} more classes._');
    }
    return md.toString();
  }

  /// Handles the force_gc tool request.
  Future<CallToolResult> _handleForceGc(CallToolRequest req) async {
    final before = await _getHeapStats();
    final after = await _getHeapStats(gc: true);

    final freedBytes = before.heapUsage - after.heapUsage;
    final freedPct = before.heapUsage > 0
        ? (freedBytes / before.heapUsage * 100).toStringAsFixed(1)
        : '0.0';

    final text = StringBuffer()
      ..writeln('| Metric | Before | After | Delta / Freed |')
      ..writeln('| :--- | :--- | :--- | :--- |')
      ..writeln(
          '| **Heap Usage** | ${formatBytes(before.heapUsage)} | ${formatBytes(after.heapUsage)} | ${formatBytes(freedBytes)} ($freedPct% freed) |')
      ..writeln(
          '| **Heap Capacity** | ${formatBytes(before.heapCapacity)} | ${formatBytes(after.heapCapacity)} | ${formatBytes(after.heapCapacity - before.heapCapacity)} |')
      ..writeln(
          '| **External Usage** | ${formatBytes(before.externalUsage)} | ${formatBytes(after.externalUsage)} | ${formatBytes(after.externalUsage - before.externalUsage)} |');

    final data = {
      'action': 'force_gc',
      'heap_before': before.heapUsage,
      'heap_after': after.heapUsage,
      'freed_bytes': freedBytes,
      'freed_percentage': freedPct,
      'capacity_before': before.heapCapacity,
      'capacity_after': after.heapCapacity,
      'external_before': before.externalUsage,
      'external_after': after.externalUsage,
    };

    return serializeDualFormat(
      title: '### Garbage Collection (force_gc) Result',
      markdownBody: text.toString(),
      structuredData: data,
    );
  }

  /// Handles the start_gc_stream tool request.
  Future<CallToolResult> _handleStartGcStream(CallToolRequest req) async {
    await _ensureGcStream();
    return serializeDualFormat(
      title: '### GC Stream Monitoring Started',
      markdownBody:
          'Now collecting garbage collection events on stream `${EventStreams.kGC}`.',
      structuredData: {
        'action': 'start_gc_stream',
        'status': 'active',
        'start_timestamp': _gcStreamStartTime,
      },
    );
  }

  /// Handles the stop_gc_stream tool request.
  Future<CallToolResult> _handleStopGcStream(CallToolRequest req) async {
    final limit = req.intArg('limit', defaultValue: 50)!;
    final count = _gcEventBuffer.length;
    final durationMs = _gcStreamStartTime != null
        ? DateTime.now().millisecondsSinceEpoch - _gcStreamStartTime!
        : 0;
    final returnedEvents = _gcEventBuffer.take(limit).toList();

    await _stopGcStreamInternal(force: true);

    final text = StringBuffer()
      ..writeln('- **Duration**: ${(durationMs / 1000).toStringAsFixed(1)}s')
      ..writeln('- **Total Events Captured**: $count')
      ..writeln('- **Events Returned**: ${returnedEvents.length}');

    if (returnedEvents.isNotEmpty) {
      text.writeln('\n#### Recent GC Events');
      for (final e in returnedEvents) {
        text.writeln(
            '- Type: ${e['gcType'] ?? e['kind']} at ${e['timestamp']}');
      }
    }

    final data = {
      'action': 'stop_gc_stream',
      'status': 'stopped',
      'duration_ms': durationMs,
      'total_events': count,
      'events': returnedEvents,
    };

    _gcEventBuffer.clear();

    return serializeDualFormat(
      title: '### GC Stream Monitoring Stopped',
      markdownBody: text.toString(),
      structuredData: data,
    );
  }

  /// Handles the get_memory_timeline tool request.
  Future<CallToolResult> _handleGetMemoryTimeline(CallToolRequest req) async {
    final duration =
        req.intArg('durationSeconds', defaultValue: 5)!.clamp(1, 60);

    final wasActive = _gcStreamActive;
    if (!wasActive) {
      await _ensureGcStream();
    }

    final samples = <MemoryTimelineSample>[];
    final startEventCount = _gcEventBuffer.length;
    var lastCheckEventCount = startEventCount;
    SamplingResult? sampleResult;

    for (var i = 0; i <= duration; i++) {
      if (i > 0) {
        final res = await safeSamplingWindow(
          vmService: vmService,
          duration: const Duration(seconds: 1),
        );
        if (!res.completed) {
          sampleResult = res;
          break;
        }
      }
      try {
        final heap = await _getHeapStats();
        final rss = await _getRssBytes();
        final currentEventCount = _gcEventBuffer.length;
        final gcInInterval = currentEventCount - lastCheckEventCount;
        lastCheckEventCount = currentEventCount;

        samples.add(MemoryTimelineSample(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          heapUsed: heap.heapUsage,
          heapCapacity: heap.heapCapacity,
          externalUsage: heap.externalUsage,
          rss: rss,
          gcEventsInInterval: gcInInterval,
        ));
      } catch (_) {
        sampleResult = SamplingResult(
          completed: false,
          elapsed: Duration(seconds: i),
          interruptReason: 'vm_service_disconnected',
        );
        break;
      }
    }

    if (!wasActive) {
      await _stopGcStreamInternal();
    }

    sampleResult ??= SamplingResult(
      completed: true,
      elapsed: Duration(seconds: samples.length),
    );

    final text = StringBuffer();
    sampleResult.writeWarningIfInterrupted(
      text,
      requestedSeconds: duration,
      dataName: 'timeline',
    );
    text
      ..writeln(
          '| Timestamp | Heap Used | Heap Capacity | External | RSS | GC Events |')
      ..writeln('| :--- | :--- | :--- | :--- | :--- | :--- |');

    for (final s in samples) {
      final timeStr = DateTime.fromMillisecondsSinceEpoch(s.timestamp)
          .toLocal()
          .toString()
          .split(' ')
          .last
          .split('.')
          .first;
      text.writeln(
          '| $timeStr | ${formatBytes(s.heapUsed)} | ${formatBytes(s.heapCapacity)} | ${formatBytes(s.externalUsage)} | ${formatBytes(s.rss)} | ${s.gcEventsInInterval} |');
    }

    final data = {
      'action': 'get_memory_timeline',
      'duration_seconds': duration,
      'sample_count': samples.length,
      'samples': samples.map((s) => s.toMap()).toList(),
    };

    return serializeDualFormat(
      title: '### Memory Timeline (${duration}s recording)',
      markdownBody: text.toString(),
      structuredData: data,
    );
  }

  /// Handles the watch_gc_pressure tool request.
  Future<CallToolResult> _handleWatchGcPressure(CallToolRequest req) async {
    final duration =
        req.intArg('durationSeconds', defaultValue: 10)!.clamp(1, 60);
    final limit = req.intArg('limit', defaultValue: 50)!;

    final wasActive = _gcStreamActive;
    if (!wasActive) {
      await _ensureGcStream();
    }

    final startIndex = _gcEventBuffer.length;
    final sampleResult = await safeSamplingWindow(
      vmService: vmService,
      duration: Duration(seconds: duration),
    );

    final newEvents = _gcEventBuffer.skip(startIndex).toList();
    if (!wasActive) {
      await _stopGcStreamInternal();
    }

    final gcCount = newEvents.length;
    final gcPerSec = gcCount / duration;

    String pressureLevel;
    if (gcPerSec < 0.5) {
      pressureLevel = 'low';
    } else if (gcPerSec <= 2.0) {
      pressureLevel = 'moderate';
    } else {
      pressureLevel = 'high';
    }

    // Inter-GC intervals
    final intervals = <double>[];
    for (var i = 1; i < newEvents.length; i++) {
      final prev = newEvents[i - 1]['timestamp'] as int;
      final curr = newEvents[i]['timestamp'] as int;
      intervals.add((curr - prev) / 1000.0);
    }
    final avgInterval = intervals.isNotEmpty
        ? (intervals.reduce((a, b) => a + b) / intervals.length)
            .toStringAsFixed(2)
        : 'N/A';

    // gcType distribution
    final typeCounts = <String, int>{};
    for (final e in newEvents) {
      final type = (e['gcType'] as String?) ?? 'Unknown';
      typeCounts[type] = (typeCounts[type] ?? 0) + 1;
    }

    final text = StringBuffer();
    sampleResult.writeWarningIfInterrupted(
      text,
      requestedSeconds: duration,
      dataName: 'GC events',
    );
    text
      ..writeln('- **Pressure Level**: `${pressureLevel.toUpperCase()}`')
      ..writeln('- **GC Event Count**: $gcCount')
      ..writeln('- **GC Frequency**: ${gcPerSec.toStringAsFixed(2)} GC/sec')
      ..writeln('- **Avg Inter-GC Interval**: ${avgInterval}s');

    if (typeCounts.isNotEmpty) {
      text.writeln('- **GC Type Distribution**:');
      typeCounts.forEach((type, count) {
        text.writeln('  - $type: $count');
      });
    }

    final returnedEvents = newEvents.take(limit).toList();

    final data = {
      'action': 'watch_gc_pressure',
      'duration_seconds': duration,
      'pressure_level': pressureLevel,
      'gc_count': gcCount,
      'gc_frequency_per_sec': gcPerSec,
      'avg_interval_seconds': avgInterval,
      'gc_type_distribution': typeCounts,
      'events': returnedEvents,
    };

    return serializeDualFormat(
      title: '### GC Pressure Analysis (${duration}s window)',
      markdownBody: text.toString(),
      structuredData: data,
    );
  }

  /// Handles the explain_memory_breakdown tool request.
  Future<CallToolResult> _handleExplainMemoryBreakdown(
      CallToolRequest req) async {
    final rss = await _getRssBytes();
    final heap = await _getHeapStats();

    int? rasterBytes;
    try {
      final rasterRes = await vmService!.callServiceExtension(
        'ext.ui.window.getSkiaEstimateRasterCacheMemory',
        isolateId: isolateId!,
      );
      final json = rasterRes.json;
      if (json != null && json.containsKey('result')) {
        rasterBytes = json['result'] as int?;
      }
    } catch (e) {
      stderr.writeln(
          '[mcp:memory] Raster cache memory extension unavailable: $e');
    }

    final text = StringBuffer()
      ..writeln('- **Resident Set Size (RSS)**: ${formatBytes(rss)}')
      ..writeln(
          '  _Total physical memory allocated to the application process by the operating system._')
      ..writeln()
      ..writeln(
          '- **Dart Heap Used**: ${formatBytes(heap.heapUsage)} / ${formatBytes(heap.heapCapacity)} (${(heap.heapCapacity > 0 ? (heap.heapUsage / heap.heapCapacity * 100) : 0).toStringAsFixed(1)}% capacity)')
      ..writeln(
          '  _Memory managed directly by the Dart garbage collector for Dart objects._')
      ..writeln()
      ..writeln('- **External Memory**: ${formatBytes(heap.externalUsage)}')
      ..writeln(
          '  _Native memory bound to Dart objects (e.g. image bytes, native plugin buffers)._');

    if (rasterBytes != null) {
      text
        ..writeln()
        ..writeln('- **Raster Cache**: ${formatBytes(rasterBytes)}')
        ..writeln(
            '  _GPU memory reserved for rendered picture and image raster caches._');
    } else {
      text
        ..writeln()
        ..writeln('- **Raster Cache**: N/A (service extension unavailable)');
    }

    final data = {
      'action': 'explain_memory_breakdown',
      'rss_bytes': rss,
      'heap_used_bytes': heap.heapUsage,
      'heap_capacity_bytes': heap.heapCapacity,
      'external_bytes': heap.externalUsage,
      if (rasterBytes != null) 'raster_cache_bytes': rasterBytes,
    };

    return serializeDualFormat(
      title: '### Memory Usage Breakdown',
      markdownBody: text.toString(),
      structuredData: data,
    );
  }

  /// Handles the memory composite tool request.
  Future<CallToolResult> _handleMemory(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    if (action != 'list' && (vmService == null || isolateId == null)) {
      return notConnected();
    }
    return switch (action) {
      'get_snapshot' => _handleGetMemorySnapshot(req),
      'save' => _handleSaveSnapshot(req),
      'compare' => _handleCompareSnapshots(req),
      'list' => _handleListSnapshots(req),
      'audit_leak' => _handleAuditClassMemoryLeak(req),
      'diff_allocations' => _handleDiffHeapAllocations(req),
      'get_referrers' => _handleGetObjectReferrers(req),
      'force_gc' => _handleForceGc(req),
      'start_gc_stream' => _handleStartGcStream(req),
      'stop_gc_stream' => _handleStopGcStream(req),
      'get_memory_timeline' => _handleGetMemoryTimeline(req),
      'watch_gc_pressure' => _handleWatchGcPressure(req),
      'explain_memory_breakdown' => _handleExplainMemoryBreakdown(req),
      _ => CallToolResult(
          content: [TextContent(text: 'Unknown memory action: $action')],
          isError: true,
        ),
    };
  }

  /// Helper to process a list of items asynchronously in fixed-size batches.
  Future<List<R>> _batchAsync<T, R>(
    List<T> items,
    Future<R> Function(T item) mapper, {
    int chunkSize = 5,
  }) async {
    final results = <R>[];
    for (var i = 0; i < items.length; i += chunkSize) {
      final end = (i + chunkSize < items.length) ? i + chunkSize : items.length;
      final chunk = items.sublist(i, end);
      final chunkResults = await Future.wait(chunk.map(mapper));
      results.addAll(chunkResults);
    }
    return results;
  }
}
