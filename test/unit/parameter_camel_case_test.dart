import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/flutter_agent_lens.dart';
import 'package:flutter_agent_lens/src/enums/breakpoint_action.dart';
import 'package:flutter_agent_lens/src/enums/connection_action.dart';
import 'package:flutter_agent_lens/src/enums/console_log_action.dart';
import 'package:flutter_agent_lens/src/enums/debug_flag_action.dart';
import 'package:flutter_agent_lens/src/enums/diagnose_action.dart';
import 'package:flutter_agent_lens/src/enums/memory_action.dart';
import 'package:flutter_agent_lens/src/enums/network_action.dart';
import 'package:flutter_agent_lens/src/enums/profiling_action.dart';
import 'package:flutter_agent_lens/src/enums/rebuild_tracking_action.dart';
import 'package:flutter_agent_lens/src/enums/screenshot_types.dart';
import 'package:flutter_agent_lens/src/enums/widget_action.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// Matches MCP request argument reads that pass a literal string key, e.g.
/// `.arg<String>('key')`, `.requireArg('key')`, `.intArg('key')`.
final RegExp _mcpArgRead = RegExp(
  r"\.(?:arg|requireArg|intArg|doubleArg|strArg)(?:<[^>]*>)?\(\s*'([^']+)'"
  r"|(?:^|[^.\w])requireArg(?:<[^>]*>)?\(\s*'([^']+)'",
);

void main() {
  group('MCP Tool Parameter Casing Tests', () {
    late FlutterAgentLensServer server;
    late StreamChannelController<String> channelController;

    setUp(() async {
      channelController = StreamChannelController<String>();
      server = FlutterAgentLensServer(channel: channelController.foreign);
      await server.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.v2024_11_05,
          capabilities: ClientCapabilities(),
          clientInfo: Implementation(name: 'test_client', version: '1.0.0'),
        ),
      );
      server.registerConnectedTools();
    });

    tearDown(() async {
      await channelController.local.sink.close();
    });

    test('All registered MCP tool schema property names are camelCase',
        () async {
      final listResult = await server.listTools(ListToolsRequest());
      final tools = listResult.tools;
      expect(tools, isNotEmpty);

      final multiWordUnderscoreParams = <String>[];

      for (final tool in tools) {
        final schema = tool.inputSchema;
        final properties = schema.properties;
        if (properties == null) continue;
        for (final paramName in properties.keys) {
          if (paramName.contains('_')) {
            multiWordUnderscoreParams.add('${tool.name}.$paramName');
          }
        }
      }

      expect(
        multiWordUnderscoreParams,
        isEmpty,
        reason:
            'The following tool parameters contain underscores and should be camelCase: $multiWordUnderscoreParams',
      );
    });

    test('Specific parameters are correctly converted to camelCase', () async {
      final listResult = await server.listTools(ListToolsRequest());
      final toolsByName = {for (final t in listResult.tools) t.name: t};

      expect(toolsByName['connection']?.inputSchema.properties?.keys,
          contains('workspaceRoot'));
      expect(toolsByName['discover_apps']?.inputSchema.properties?.keys,
          contains('workspaceRoot'));
      expect(toolsByName['console_logs']?.inputSchema.properties?.keys,
          contains('durationSeconds'));
      expect(toolsByName['debug_flag']?.inputSchema.properties?.keys,
          contains('flagName'));
      expect(toolsByName['breakpoint']?.inputSchema.properties?.keys,
          containsAll(['filePath', 'breakpointId']));
      expect(toolsByName['evaluate_expression']?.inputSchema.properties?.keys,
          contains('frameIndex'));
      expect(
          toolsByName['diagnose_project']?.inputSchema.properties?.keys,
          containsAll([
            'buildTarget',
            'targetPlatform',
            'analysisPath',
            'buildVariant'
          ]));
      expect(
          toolsByName['memory']?.inputSchema.properties?.keys,
          containsAll([
            'className',
            'durationSeconds',
            'objectId',
            'filterZeroDeltas',
            'forceGc'
          ]));
      expect(
          toolsByName['network']?.inputSchema.properties?.keys,
          containsAll(
              ['durationSeconds', 'slowThresholdMs', 'includeDetails']));
      expect(toolsByName['profiling']?.inputSchema.properties?.keys,
          contains('durationSeconds'));
      expect(toolsByName['rebuild_tracking']?.inputSchema.properties?.keys,
          containsAll(['durationSeconds', 'excludeFlutterWidgets']));
      expect(
          toolsByName['screenshot']?.inputSchema.properties?.keys,
          containsAll(
              ['baselineName', 'screenshotType', 'deviceId', 'outputPath']));
      expect(
          toolsByName['trigger_scroll_gesture']?.inputSchema.properties?.keys,
          contains('scrollControllerExpression'));
    });

    test('No MCP argument reads use snake_case keys', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        for (final match in _mcpArgRead.allMatches(source)) {
          final key = match.group(1) ?? match.group(2);
          if (key != null && key.contains('_')) {
            offenders.add('${entity.path}: "$key"');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'MCP argument reads still use snake_case keys: $offenders',
      );
    });

    test('Tool names use snake_case conventions', () async {
      final listResult = await server.listTools(ListToolsRequest());
      final tools = listResult.tools;
      expect(tools, isNotEmpty);

      for (final tool in tools) {
        expect(tool.name, matches(RegExp(r'^[a-z0-9_]+$')),
            reason: 'Tool name ${tool.name} should be snake_case');
      }
    });

    test('Action enums round-trip fromString correctly', () {
      for (final e in MemoryAction.values) {
        expect(MemoryAction.fromString(e.value), equals(e));
      }
      for (final e in NetworkAction.values) {
        expect(NetworkAction.fromString(e.value), equals(e));
      }
      for (final e in ProfilingAction.values) {
        expect(ProfilingAction.fromString(e.value), equals(e));
      }
      for (final e in RebuildTrackingAction.values) {
        expect(RebuildTrackingAction.fromString(e.value), equals(e));
      }
      for (final e in WidgetAction.values) {
        expect(WidgetAction.fromString(e.value), equals(e));
      }
      for (final e in DebugFlagAction.values) {
        expect(DebugFlagAction.fromString(e.value), equals(e));
      }
      for (final e in ConnectionAction.values) {
        expect(ConnectionAction.fromString(e.value), equals(e));
      }
      for (final e in ConsoleLogAction.values) {
        expect(ConsoleLogAction.fromString(e.value), equals(e));
      }
      for (final e in BreakpointAction.values) {
        expect(BreakpointAction.fromString(e.value), equals(e));
      }
      for (final e in DiagnoseAction.values) {
        expect(DiagnoseAction.fromString(e.value), equals(e));
      }
      for (final e in ScreenshotAction.values) {
        expect(ScreenshotAction.fromString(e.value), equals(e));
      }
    });
  });
}
