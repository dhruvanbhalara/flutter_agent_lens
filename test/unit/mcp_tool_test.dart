import 'package:test/test.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/enums/target_platform.dart';
import 'package:flutter_agent_lens/src/enums/network_sort_by.dart';
import 'package:flutter_agent_lens/src/enums/exception_pause_mode.dart';
import 'package:flutter_agent_lens/src/enums/screenshot_types.dart';

void main() {
  group('McpTool Enum Tests', () {
    test('fromName returns correct enum or null', () {
      expect(McpTool.fromName('connection'), equals(McpTool.connection));
      expect(McpTool.fromName('memory'), equals(McpTool.memory));
      expect(McpTool.fromName('non_existent'), isNull);
    });

    test('requiresConnection validation', () {
      expect(McpTool.connection.requiresConnection, isFalse);
      expect(McpTool.discoverApps.requiresConnection, isFalse);
      expect(McpTool.memory.requiresConnection, isTrue);
    });
  });

  group('TargetPlatform Enum Tests', () {
    test('fromString parsed successfully', () {
      expect(
          TargetPlatform.fromString('android'), equals(TargetPlatform.android));
      expect(TargetPlatform.fromString('ios'), equals(TargetPlatform.ios));
      expect(() => TargetPlatform.fromString('windows'), throwsArgumentError);
    });
  });

  group('NetworkSortBy Enum Tests', () {
    test('fromString parsed successfully', () {
      expect(NetworkSortBy.fromString('time'), equals(NetworkSortBy.time));
      expect(
          NetworkSortBy.fromString('duration'), equals(NetworkSortBy.duration));
      expect(NetworkSortBy.fromString('size'), equals(NetworkSortBy.size));
      expect(NetworkSortBy.fromString('invalid'), equals(NetworkSortBy.time));
    });
  });

  group('ExceptionPauseMode Enum Tests', () {
    test('fromString parsed successfully', () {
      expect(ExceptionPauseMode.fromString('none'),
          equals(ExceptionPauseMode.none));
      expect(
          ExceptionPauseMode.fromString('all'), equals(ExceptionPauseMode.all));
      expect(ExceptionPauseMode.fromString('unhandled'),
          equals(ExceptionPauseMode.unhandled));
      expect(ExceptionPauseMode.fromString('invalid'),
          equals(ExceptionPauseMode.none));
    });
  });

  group('ScreenshotType Enum Tests', () {
    test('ScreenshotAction and ScreenshotType parsed successfully', () {
      expect(ScreenshotAction.fromString('capture_baseline'),
          equals(ScreenshotAction.captureBaseline));
      expect(ScreenshotAction.fromString('compare'),
          equals(ScreenshotAction.compare));
      expect(() => ScreenshotAction.fromString('invalid'), throwsArgumentError);

      expect(
          ScreenshotType.fromString('device'), equals(ScreenshotType.device));
      expect(ScreenshotType.fromString('skia'), equals(ScreenshotType.skia));
      expect(
          ScreenshotType.fromString('invalid'), equals(ScreenshotType.device));
    });
  });
}
