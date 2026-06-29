import 'package:flutter_agent_lens/src/mixins/debugger_support.dart';
import 'package:flutter_agent_lens/src/mixins/deeplink_validation_support.dart';
import 'package:flutter_agent_lens/src/mixins/network_capture_support.dart';
import 'package:flutter_agent_lens/src/mixins/screenshot_support.dart';
import 'package:flutter_agent_lens/src/mixins/widget_inspection_support.dart';
import 'package:test/test.dart';

void main() {
  group('FlutterDebugFlag', () {
    test('parses debugPaint', () {
      expect(
        FlutterDebugFlag.fromString('debugPaint'),
        equals(FlutterDebugFlag.debugPaint),
      );
      expect(
        FlutterDebugFlag.fromString('debugpaint'),
        equals(FlutterDebugFlag.debugPaint),
      );
      expect(
        FlutterDebugFlag.fromString('DEBUGPAINT'),
        equals(FlutterDebugFlag.debugPaint),
      );
    });

    test('parses repaintRainbow', () {
      expect(
        FlutterDebugFlag.fromString('repaintRainbow'),
        equals(FlutterDebugFlag.repaintRainbow),
      );
    });

    test('defaults to debugPaint for unknown flags', () {
      expect(
        FlutterDebugFlag.fromString('unknown_flag'),
        equals(FlutterDebugFlag.debugPaint),
      );
    });
  });

  group('ScreenshotAction', () {
    test('parses capture_baseline', () {
      expect(
        ScreenshotAction.fromString('capture_baseline'),
        equals(ScreenshotAction.captureBaseline),
      );
      expect(
        ScreenshotAction.fromString('CAPTURE_BASELINE'),
        equals(ScreenshotAction.captureBaseline),
      );
    });

    test('throws ArgumentError for unknown action', () {
      expect(() => ScreenshotAction.fromString('unknown'), throwsArgumentError);
    });
  });

  group('ScreenshotType', () {
    test('parses device / skia', () {
      expect(
        ScreenshotType.fromString('device'),
        equals(ScreenshotType.device),
      );
      expect(ScreenshotType.fromString('skia'), equals(ScreenshotType.skia));
    });

    test('defaults to device when null or unknown', () {
      expect(ScreenshotType.fromString(null), equals(ScreenshotType.device));
      expect(
        ScreenshotType.fromString('unknown'),
        equals(ScreenshotType.device),
      );
    });
  });

  group('TargetPlatform', () {
    test('parses android / ios', () {
      expect(
        TargetPlatform.fromString('android'),
        equals(TargetPlatform.android),
      );
      expect(TargetPlatform.fromString('ios'), equals(TargetPlatform.ios));
    });

    test('throws ArgumentError for unknown platforms', () {
      expect(() => TargetPlatform.fromString('web'), throwsArgumentError);
    });
  });

  group('ExceptionPauseMode', () {
    test('parses all modes', () {
      expect(
        ExceptionPauseMode.fromString('none'),
        equals(ExceptionPauseMode.none),
      );
      expect(
        ExceptionPauseMode.fromString('all'),
        equals(ExceptionPauseMode.all),
      );
      expect(
        ExceptionPauseMode.fromString('unhandled'),
        equals(ExceptionPauseMode.unhandled),
      );
    });

    test('defaults to none for unknown mode', () {
      expect(
        ExceptionPauseMode.fromString('unknown'),
        equals(ExceptionPauseMode.none),
      );
    });
  });

  group('NetworkSortBy', () {
    test('parses time / duration / size', () {
      expect(NetworkSortBy.fromString('time'), equals(NetworkSortBy.time));
      expect(
        NetworkSortBy.fromString('duration'),
        equals(NetworkSortBy.duration),
      );
      expect(NetworkSortBy.fromString('size'), equals(NetworkSortBy.size));
    });

    test('defaults to time when null or unknown', () {
      expect(NetworkSortBy.fromString(null), equals(NetworkSortBy.time));
      expect(NetworkSortBy.fromString('unknown'), equals(NetworkSortBy.time));
    });
  });
}
