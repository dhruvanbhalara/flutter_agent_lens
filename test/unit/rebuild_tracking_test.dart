import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/mixins/rebuild_tracking_support.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/utils/workspace_package_resolver.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

base class RebuildTrackingMock extends MCPServer
    with ToolsSupport, VmConnectionSupport, RebuildTrackingSupport {
  RebuildTrackingMock(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'mock', version: '1.0'),
        );

  @override
  void registerConnectedTools() {}

  @override
  void unregisterConnectedTools() {}
}

class FakeVmServiceForRebuilds extends vm_service.VmService {
  final StreamController<vm_service.Event> _eventController =
      StreamController<vm_service.Event>.broadcast();

  FakeVmServiceForRebuilds() : super(const Stream<dynamic>.empty(), (msg) {});

  @override
  Stream<vm_service.Event> get onExtensionEvent => _eventController.stream;

  void emitRebuildEvent(Map<String, dynamic> data) {
    _eventController.add(vm_service.Event(
      kind: 'Extension',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      extensionKind: 'Flutter.RebuiltWidgets',
      extensionData: vm_service.ExtensionData.parse(data),
    ));
  }

  @override
  Future<vm_service.Isolate> getIsolate(String isolateId) async {
    return vm_service.Isolate(
      id: 'isolate_1',
      name: 'main',
      extensionRPCs: [
        'ext.flutter.inspector.trackRebuildDirtyWidgets',
        'ext.flutter.inspector.widgetLocationIdMap',
      ],
      libraries: [
        vm_service.LibraryRef(
          id: 'lib_1',
          name: 'my_app',
          uri: 'package:my_app/main.dart',
        ),
      ],
    );
  }

  @override
  Future<vm_service.Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    if (method == 'ext.flutter.inspector.widgetLocationIdMap') {
      final parsed = vm_service.Response.parse({
        'result': {
          'package:my_app/main.dart': {
            'ids': [1, 2],
            'lines': [10, 20],
            'names': ['MyWidget', 'AppScreen']
          },
          'package:flutter/src/widgets/container.dart': {
            'ids': [3, 4],
            'lines': [100, 200],
            'names': ['Container', 'Padding']
          },
          'package:flutter/src/material/scaffold.dart': {
            'ids': [5],
            'lines': [50],
            'names': ['Scaffold']
          },
          'package:provider/src/provider.dart': {
            'ids': [6],
            'lines': [30],
            'names': ['Provider']
          },
          'dart:ui/geometry.dart': {
            'ids': [7],
            'lines': [15],
            'names': ['Offset']
          }
        }
      });
      if (parsed == null) {
        throw StateError('Failed to parse mock Response');
      }
      return parsed;
    }
    final parsed = vm_service.Response.parse({'type': 'Success'});
    if (parsed == null) {
      throw StateError('Failed to parse mock Response');
    }
    return parsed;
  }
}

void main() {
  late StreamChannelController<String> controller;
  late RebuildTrackingMock mock;

  setUp(() {
    controller = StreamChannelController<String>();
    mock = RebuildTrackingMock(controller.local);
    mock.registerRebuildTrackingTools();
    mock.vmService = FakeVmServiceForRebuilds();
    mock.isolateId = 'isolate_1';
  });

  group('RebuildTrackingSupport Tests', () {
    test(
        'Default filtering (exclude_flutter_widgets omitted) only returns project widgets',
        () async {
      unawaited(Future.delayed(const Duration(milliseconds: 100), () {
        (mock.vmService! as FakeVmServiceForRebuilds).emitRebuildEvent({
          'events': [1, 10, 2, 20, 3, 5, 5, 2, 6, 8, 7, 4]
        });
      }));

      final result = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'get_counts',
            'duration_seconds': 1,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('AppScreen'));
      expect(text, contains('MyWidget'));
      expect(text, isNot(contains('Container')));
      expect(text, isNot(contains('Scaffold')));
      expect(text, isNot(contains('Provider')));
      expect(text, isNot(contains('Offset')));
      expect(text, contains('Note: Built-in Flutter/SDK widgets excluded.'));
    });

    test('Explicit exclude_flutter_widgets: true only returns project widgets',
        () async {
      unawaited(Future.delayed(const Duration(milliseconds: 100), () {
        (mock.vmService! as FakeVmServiceForRebuilds).emitRebuildEvent({
          'events': [1, 10, 3, 5]
        });
      }));

      final result = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'get_counts',
            'duration_seconds': 1,
            'exclude_flutter_widgets': true,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('MyWidget'));
      expect(text, isNot(contains('Container')));
    });

    test(
        'Explicit exclude_flutter_widgets: false returns all widgets including SDK and packages',
        () async {
      unawaited(Future.delayed(const Duration(milliseconds: 100), () {
        (mock.vmService! as FakeVmServiceForRebuilds).emitRebuildEvent({
          'events': [1, 10, 3, 5, 6, 8, 7, 2]
        });
      }));

      final result = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'get_counts',
            'duration_seconds': 1,
            'exclude_flutter_widgets': false,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('MyWidget'));
      expect(text, contains('Container'));
      expect(text, contains('Provider'));
      expect(text, contains('Offset'));
      expect(text,
          isNot(contains('Note: Built-in Flutter/SDK widgets excluded.')));
    });

    test('All SDK widgets filtered results in graceful empty message',
        () async {
      unawaited(Future.delayed(const Duration(milliseconds: 100), () {
        (mock.vmService! as FakeVmServiceForRebuilds).emitRebuildEvent({
          'events': [3, 5, 5, 2]
        });
      }));

      final result = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'get_counts',
            'duration_seconds': 1,
            'exclude_flutter_widgets': true,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('No rebuilds captured.'));
    });

    test(
        'Response contains total_recorded_widgets and filtered_count in JSON format',
        () async {
      mock.responseFormat = 'json';

      unawaited(Future.delayed(const Duration(milliseconds: 100), () {
        (mock.vmService! as FakeVmServiceForRebuilds).emitRebuildEvent({
          'events': [1, 10, 3, 5, 6, 2]
        });
      }));

      final result = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'get_counts',
            'duration_seconds': 1,
            'exclude_flutter_widgets': true,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('total_recorded_widgets'));
      expect(text, contains('filtered_count'));

      final data = jsonDecode(
              text.replaceFirst('```json\n', '').replaceFirst('\n```', ''))
          as Map<String, dynamic>;
      expect(data['total_recorded_widgets'], 3);
      expect(data['filtered_count'], 1);
    });

    test(
        'Start/stop flow with exclude_flutter_widgets: true only returns project widgets',
        () async {
      // Start tracking
      final startRes = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'start',
          },
        ),
      );
      expect(startRes.isError, isNot(isTrue));

      // Emit events
      (mock.vmService! as FakeVmServiceForRebuilds).emitRebuildEvent({
        'events': [1, 10, 3, 5]
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Stop tracking
      final stopRes = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'stop',
            'exclude_flutter_widgets': true,
          },
        ),
      );

      expect(stopRes.isError, isNot(isTrue));
      final text = (stopRes.content.first as TextContent).text;
      expect(text, contains('Filtered widgets: 1'));
      expect(text, contains('MyWidget'));
      expect(text, isNot(contains('Container')));
    });

    test(
        'Start/stop flow with exclude_flutter_widgets: false returns all widgets',
        () async {
      // Start tracking
      final startRes = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'start',
          },
        ),
      );
      expect(startRes.isError, isNot(isTrue));

      // Emit events
      (mock.vmService! as FakeVmServiceForRebuilds).emitRebuildEvent({
        'events': [1, 10, 3, 5]
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Stop tracking
      final stopRes = await mock.callTool(
        CallToolRequest(
          name: 'rebuild_tracking',
          arguments: const {
            'action': 'stop',
            'exclude_flutter_widgets': false,
          },
        ),
      );

      expect(stopRes.isError, isNot(isTrue));
      final text = (stopRes.content.first as TextContent).text;
      expect(text, isNot(contains('Filtered widgets')));
      expect(text, contains('MyWidget'));
      expect(text, contains('Container'));
    });

    test('Helper isBuiltInWidget behaves correctly for all types of paths', () {
      // Mock workspace root set
      mock.workspaceRoot = '/Users/user/project';

      // Project file
      expect(
          mock.isBuiltInWidget('/Users/user/project/lib/main.dart:10',
              projectName: 'my_app'),
          isFalse);

      // Standard packages URIs
      expect(
          mock.isBuiltInWidget('package:flutter/src/widgets/container.dart:100',
              projectName: 'my_app'),
          isTrue);
      expect(
          mock.isBuiltInWidget('package:flutter_test/src/widget_tester.dart:12',
              projectName: 'my_app'),
          isTrue);
      expect(
          mock.isBuiltInWidget('package:provider/src/provider.dart:30',
              projectName: 'my_app'),
          isTrue);

      // User package unresolved path
      expect(
          mock.isBuiltInWidget('package:my_app/main.dart:10',
              projectName: 'my_app'),
          isFalse);

      // Puro, FVM, Mise, pub-cache paths
      expect(
          mock.isBuiltInWidget(
              '/Users/user/.puro/envs/stable/flutter/packages/flutter/lib/src/widgets/basic.dart:50',
              projectName: 'my_app'),
          isTrue);
      expect(
          mock.isBuiltInWidget(
              '/Users/user/.fvm/flutter_sdk/packages/flutter/lib/src/widgets/basic.dart:50',
              projectName: 'my_app'),
          isTrue);
      expect(
          mock.isBuiltInWidget(
              '/Users/user/fvm/versions/3.22.0/packages/flutter/lib/src/widgets/basic.dart:50',
              projectName: 'my_app'),
          isTrue);
      expect(
          mock.isBuiltInWidget(
              '/Users/user/.mise/installs/flutter/3.22.0/packages/flutter/lib/src/widgets/basic.dart:50',
              projectName: 'my_app'),
          isTrue);
      expect(
          mock.isBuiltInWidget(
              '/Users/user/.pub-cache/hosted/pub.dev/provider-6.1.2/lib/provider.dart:10',
              projectName: 'my_app'),
          isTrue);

      // Sky engine
      expect(
          mock.isBuiltInWidget(
              '/Users/user/flutter/bin/cache/pkg/sky_engine/lib/ui/geometry.dart:10',
              projectName: 'my_app'),
          isTrue);

      // dart: and org-dartlang-sdk: schemes
      expect(
          mock.isBuiltInWidget('dart:ui/geometry.dart:10',
              projectName: 'my_app'),
          isTrue);
      expect(
          mock.isBuiltInWidget(
              'org-dartlang-sdk:///flutter/lib/src/widgets/basic.dart:5',
              projectName: 'my_app'),
          isTrue);

      // Path outside workspace
      expect(
          mock.isBuiltInWidget('/Users/user/another_project/lib/helper.dart:15',
              projectName: 'my_app'),
          isTrue);

      // Relative path check
      expect(
          mock.isBuiltInWidget('/Users/user/project/lib/../lib/main.dart:10',
              projectName: 'my_app'),
          isFalse);
    });

    test(
        'Helper isBuiltInWidget falls back gracefully when workspaceRoot is null',
        () {
      mock.workspaceRoot = null;

      // Project unresolved package URI
      expect(
          mock.isBuiltInWidget('package:my_app/main.dart:10',
              projectName: 'my_app'),
          isFalse);

      // Flutter package URI
      expect(
          mock.isBuiltInWidget('package:flutter/src/widgets/container.dart:100',
              projectName: 'my_app'),
          isTrue);

      // Standard dependency package URI
      expect(
          mock.isBuiltInWidget('package:provider/src/provider.dart:30',
              projectName: 'my_app'),
          isTrue);

      // Local relative path structure
      expect(
          mock.isBuiltInWidget('/Users/user/project/lib/main.dart:10',
              projectName: 'my_app'),
          isFalse);

      // Known pub-cache / puro path checks
      expect(
          mock.isBuiltInWidget(
              '/Users/user/.pub-cache/hosted/pub.dev/provider-6.1.2/lib/provider.dart:10',
              projectName: 'my_app'),
          isTrue);
    });

    test('Helper isBuiltInWidget dynamically respects packageResolver', () {
      mock.workspaceRoot = '/Users/user/project';
      mock.isBuiltInWidgetCache.clear();

      // Set up resolver with known local and external packages
      final resolver = WorkspacePackageResolver('/Users/user/project');
      resolver.addLocalPackage('my_app');
      resolver.addLocalPackage('local_package');
      resolver.addExternalPackage('provider');
      resolver.addExternalPackage('flutter_animate');
      mock.packageResolver = resolver;

      // Local packages
      expect(
          mock.isBuiltInWidget('package:my_app/main.dart:10',
              projectName: 'some_other_name'),
          isFalse);
      expect(
          mock.isBuiltInWidget('package:local_package/widgets/button.dart:42',
              projectName: 'some_other_name'),
          isFalse);

      // External packages
      expect(
          mock.isBuiltInWidget('package:provider/provider.dart:5',
              projectName: 'some_other_name'),
          isTrue);
      expect(
          mock.isBuiltInWidget('package:flutter_animate/animate.dart:2',
              projectName: 'some_other_name'),
          isTrue);
    });

    test(
        'Helper isBuiltInWidget handles relative paths and optimizes cache key representation',
        () {
      mock.workspaceRoot = '/Users/user/project';
      mock.isBuiltInWidgetCache.clear();

      // Relative paths should resolve to absolute workspace paths and be treated as local
      expect(mock.isBuiltInWidget('lib/main.dart:10', projectName: 'my_app'),
          isFalse);
      expect(
          mock.isBuiltInWidget('src/widgets/button.dart:42',
              projectName: 'my_app'),
          isFalse);

      // Verify line numbers are stripped from cache keys
      expect(mock.isBuiltInWidgetCache.containsKey('lib/main.dart'), isTrue);
      expect(
          mock.isBuiltInWidgetCache.containsKey('lib/main.dart:10'), isFalse);
    });
  });
}
