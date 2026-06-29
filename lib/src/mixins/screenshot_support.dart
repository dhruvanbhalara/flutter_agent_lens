import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import '../enums/mcp_tool.dart';
import 'vm_connection_support.dart';

/// Support mixin providing tools for taking and visually comparing screenshots.
base mixin ScreenshotSupport on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers screenshot-related tools.
  void registerScreenshotTools() {

    registerTool(
      Tool(
        name: McpTool.compareLayoutScreenshots.name,
        description:
            'Capture screenshots and perform pixel diff checks to find layout changes or bugs.',
        inputSchema: ObjectSchema(
          properties: {
            'baseline_name': StringSchema(
              description:
                  'The filename prefix for the baseline screenshot (e.g. "home_screen").',
            ),
            'action': StringSchema(
              description:
                  'The visual operation to execute (capture_baseline, compare).',
            ),
            'threshold': NumberSchema(
              description:
                  'The similarity pass threshold from 0.0 to 1.0 (default: 0.98).',
            ),
            'screenshot_type': StringSchema(
              description:
                  'The format/method to capture (device = native screenshot, skia = Skia Picture via VM service; default: device).',
            ),
            'device_id': StringSchema(
              description:
                  'Target device ID or name if multiple devices are connected (prefixes allowed).',
            ),
            'format': formatSchema,
          },
          required: ['baseline_name', 'action'],
        ),
      ),
      _handleCompareLayoutScreenshots,
    );

    registerTool(
      Tool(
        name: McpTool.takeScreenshot.name,
        description:
            'Capture a standalone screenshot of the running Flutter application.',
        inputSchema: ObjectSchema(
          properties: {
            'screenshot_type': StringSchema(
              description:
                  'The capture method (device = native screenshot, skia = Skia Picture via VM service; default: device).',
            ),
            'device_id': StringSchema(
              description:
                  'Target device ID or name if multiple devices are connected.',
            ),
            'output_path': StringSchema(
              description:
                  'Optional destination file path. If not specified, the screenshot will be saved to a default directory.',
            ),
          },
        ),
      ),
      _handleTakeScreenshot,
    );
  }

  /// Handles the compare_layout_screenshots tool request.
  Future<CallToolResult> _handleCompareLayoutScreenshots(
      CallToolRequest req) async {
    final root = workspaceRoot;
    if (root == null || root.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Workspace root is not configured. Run connect first to set it.')
        ],
        isError: true,
      );
    }

    final baselineName = req.arguments!['baseline_name'] as String;
    final actionStr = req.arguments!['action'] as String;
    final threshold = (req.arguments?['threshold'] as num?)?.toDouble() ?? 0.98;
    final screenshotTypeStr = req.arguments?['screenshot_type'] as String?;
    final deviceId = req.arguments?['device_id'] as String?;

    final ScreenshotAction action;
    try {
      action = ScreenshotAction.fromString(actionStr);
    } catch (e) {
      return CallToolResult(
        content: [TextContent(text: e.toString())],
        isError: true,
      );
    }

    final screenshotType = ScreenshotType.fromString(screenshotTypeStr);

    stderr.writeln(
        '[mcp:screenshot] Action=${action.value}, baselineName=$baselineName, type=${screenshotType.value}, deviceId=$deviceId');

    final screenshotDir = Directory(p.join(root, 'build', 'mcp_screenshots'));
    if (!screenshotDir.existsSync()) {
      screenshotDir.createSync(recursive: true);
    }

    if (action == ScreenshotAction.captureBaseline) {
      final baselinePath =
          p.join(screenshotDir.path, '${baselineName}_baseline.png');
      stderr.writeln('[mcp:screenshot] Capturing baseline to $baselinePath');

      try {
        final actualType = await _captureDeviceScreenshot(
          targetPath: baselinePath,
          screenshotType: screenshotType.value,
          deviceId: deviceId,
        );
        final notice = (screenshotType == ScreenshotType.skia &&
                actualType == 'device')
            ? '\n(Note: Automatically fell back to native "device" screenshot because Impeller is active and Skia is unsupported)'
            : '';
        return CallToolResult(
          content: [
            TextContent(
                text:
                    'Successfully captured and saved baseline screenshot to $baselinePath$notice')
          ],
        );
      } catch (e) {
        return CallToolResult(
          content: [TextContent(text: e.toString())],
          isError: true,
        );
      }
    } else {
      final baselinePath =
          p.join(screenshotDir.path, '${baselineName}_baseline.png');
      final currentPath =
          p.join(screenshotDir.path, '${baselineName}_current.png');
      final diffPath = p.join(screenshotDir.path, '${baselineName}_diff.png');

      if (!File(baselinePath).existsSync()) {
        return CallToolResult(
          content: [
            TextContent(
                text:
                    'Baseline screenshot not found for "$baselineName". Run capture_baseline first.')
          ],
          isError: true,
        );
      }

      stderr
          .writeln('[mcp:screenshot] Capturing current screen to $currentPath');
      String actualType;
      try {
        actualType = await _captureDeviceScreenshot(
          targetPath: currentPath,
          screenshotType: screenshotType.value,
          deviceId: deviceId,
        );
      } catch (e) {
        return CallToolResult(
          content: [TextContent(text: e.toString())],
          isError: true,
        );
      }

      stderr.writeln('[mcp:screenshot] Loading images for pixel diff...');
      final baselineBytes = await File(baselinePath).readAsBytes();
      final currentBytes = await File(currentPath).readAsBytes();

      final img1 = img.decodePng(baselineBytes);
      final img2 = img.decodePng(currentBytes);

      if (img1 == null || img2 == null) {
        return CallToolResult(
          content: [
            TextContent(
                text:
                    'Failed to decode screenshots. Ensure the captured files are valid PNGs.')
          ],
          isError: true,
        );
      }

      if (img1.width != img2.width || img1.height != img2.height) {
        return CallToolResult(
          content: [
            TextContent(
              text:
                  'Layout size mismatch: Baseline is ${img1.width}x${img1.height}, '
                  'but current screen is ${img2.width}x${img2.height}.',
            )
          ],
          isError: true,
        );
      }

      var matchingPixels = 0;
      final totalPixels = img1.width * img1.height;
      final diffImage = img.Image(width: img1.width, height: img1.height);

      for (var y = 0; y < img1.height; y++) {
        for (var x = 0; x < img1.width; x++) {
          final p1 = img1.getPixel(x, y);
          final p2 = img2.getPixel(x, y);

          if (p1.r == p2.r && p1.g == p2.g && p1.b == p2.b) {
            matchingPixels++;
            diffImage.setPixel(x, y, p2);
          } else {
            diffImage.setPixel(x, y, img.ColorRgba8(255, 0, 0, 255));
          }
        }
      }

      final similarity = matchingPixels / totalPixels;
      final passed = similarity >= threshold;

      stderr.writeln('[mcp:screenshot] Saving diff image to $diffPath');
      await File(diffPath).writeAsBytes(img.encodePng(diffImage));

      final md =
          StringBuffer('Layout Screenshot Comparison: $baselineName\n\n');
      md.writeln('- Status: ${passed ? "PASS" : "FAIL"}');
      md.writeln(
          '- Similarity Score: ${(similarity * 100).toStringAsFixed(2)}% (Threshold: ${(threshold * 100).toStringAsFixed(2)}%)');
      md.writeln('- Matching Pixels: $matchingPixels / $totalPixels');
      if (screenshotType == ScreenshotType.skia && actualType == 'device') {
        md.writeln(
            '- Notice: Automatically fell back to native "device" screenshot because Impeller is active and Skia is unsupported.');
      }
      md.writeln();
      md.writeln('FILES GENERATED');
      md.writeln('- Baseline: $baselinePath');
      md.writeln('- Current: $currentPath');
      md.writeln('- Visual Diff: $diffPath');

      return serializeDualFormat(
        title: 'Visual Layout Comparison Report',
        markdownBody: md.toString(),
        structuredData: {
          'baseline_name': baselineName,
          'similarity_ratio': similarity,
          'threshold': threshold,
          'passed': passed,
          'total_pixels': totalPixels,
          'matching_pixels': matchingPixels,
          'baseline_path': baselinePath,
          'current_path': currentPath,
          'diff_path': diffPath,
        },
        format: req.arguments?['format'] as String?,
      );
    }
  }

  /// Handles the take_screenshot tool request.
  Future<CallToolResult> _handleTakeScreenshot(CallToolRequest req) async {
    final root = workspaceRoot;
    if (root == null || root.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
              text: 'Workspace root is not configured. Run connect first.')
        ],
        isError: true,
      );
    }

    final screenshotTypeStr = req.arguments?['screenshot_type'] as String?;
    final deviceId = req.arguments?['device_id'] as String?;
    final outputPath = req.arguments?['output_path'] as String?;

    final screenshotType = ScreenshotType.fromString(screenshotTypeStr);

    String targetPath;
    if (outputPath != null && outputPath.isNotEmpty) {
      targetPath = outputPath;
    } else {
      final screenshotDir = Directory(p.join(root, 'build', 'mcp_screenshots'));
      if (!screenshotDir.existsSync()) {
        screenshotDir.createSync(recursive: true);
      }
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      targetPath = p.join(screenshotDir.path, 'screenshot_$timestamp.png');
    }

    final actualType = await _captureDeviceScreenshot(
      targetPath: targetPath,
      screenshotType: screenshotType.value,
      deviceId: deviceId,
    );
    final notice = (screenshotType == ScreenshotType.skia &&
            actualType == 'device')
        ? '\n(Note: Automatically fell back to native "device" screenshot because Impeller is active and Skia is unsupported)'
        : '';
    return CallToolResult(
      content: [
        TextContent(text: 'Screenshot saved to $targetPath$notice'),
      ],
    );
  }

  /// Helper to capture a screenshot via the Flutter CLI tool.
  Future<String> _captureDeviceScreenshot({
    required String targetPath,
    required String screenshotType,
    required String? deviceId,
  }) async {
    if (vmService != null) {
      String? effectiveDeviceId = deviceId;
      String? os;

      try {
        final vm = await vmService!.getVM();
        os = vm.operatingSystem?.toLowerCase();

        if (effectiveDeviceId == null || effectiveDeviceId.isEmpty) {
          if (os != null) {
            effectiveDeviceId = await _detectDeviceForOs(os);
          }
        }
      } catch (e) {
        stderr.writeln(
            '[mcp:screenshot] Error detecting VM OS or auto-detecting device: $e');
      }

      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      final executable = flutterRoot != null
          ? p.join(flutterRoot, 'bin',
              Platform.isWindows ? 'flutter.bat' : 'flutter')
          : (Platform.isWindows ? 'flutter.bat' : 'flutter');

      final args = [
        'screenshot',
        '--out=$targetPath',
        if (screenshotType == 'skia' && vmServiceUri != null) ...[
          '--vm-service-url=$vmServiceUri',
          '--type=skia',
        ] else ...[
          '--type=device',
        ],
        if (effectiveDeviceId != null && effectiveDeviceId.isNotEmpty)
          '--device-id=$effectiveDeviceId',
      ];

      final result = await Process.run(executable, args);
      if (result.exitCode != 0) {
        final errorMsg = result.stderr.toString();
        if (screenshotType == 'skia' &&
            errorMsg.contains(
                'Cannot capture SKP screenshot with Impeller enabled.')) {
          stderr.writeln(
              '[mcp:screenshot] Skia capture blocked by Impeller. Retrying as device screenshot.');
          return _captureDeviceScreenshot(
            targetPath: targetPath,
            screenshotType: 'device',
            deviceId: deviceId,
          );
        }
        throw ProcessException(
          executable,
          args,
          'Failed to capture screenshot (Exit Code ${result.exitCode}):\n${errorMsg.trim()}',
          result.exitCode,
        );
      }
      return screenshotType;
    }
    throw StateError('VM Service is not connected.');
  }

  /// Helper to detect the active device or emulator ID matching the given OS.
  Future<String?> _detectDeviceForOs(String targetOs) async {
    try {
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      final executable = flutterRoot != null
          ? p.join(flutterRoot, 'bin',
              Platform.isWindows ? 'flutter.bat' : 'flutter')
          : (Platform.isWindows ? 'flutter.bat' : 'flutter');

      final result = await Process.run(executable, ['devices', '--machine']);
      if (result.exitCode == 0) {
        final devices = jsonDecode(result.stdout.toString()) as List<dynamic>;
        final normalizedOs = targetOs.toLowerCase();

        bool matches(Map<String, dynamic> device) {
          final platform =
              (device['targetPlatform'] as String?)?.toLowerCase() ?? '';
          final id = (device['id'] as String?)?.toLowerCase() ?? '';

          return switch (normalizedOs) {
            'android' => platform.startsWith('android'),
            'ios' => platform.startsWith('ios'),
            'macos' => platform == 'darwin' || id == 'macos',
            'windows' => platform == 'windows' || id == 'windows',
            'linux' => platform == 'linux' || id == 'linux',
            'web' => platform == 'web-javascript' || id == 'chrome',
            _ => false,
          };
        }

        final matchesList =
            devices.whereType<Map<String, dynamic>>().where(matches).toList();

        if (matchesList.isNotEmpty) {
          final emulator = matchesList.firstWhere(
            (d) => d['emulator'] == true,
            orElse: () => matchesList.first,
          );
          return emulator['id'] as String?;
        }
      }
    } catch (e) {
      stderr.writeln('[mcp:screenshot] Error listing/matching devices: $e');
    }
    return null;
  }
}

/// The visual screenshot comparison action.
enum ScreenshotAction {
  /// Capture baseline screenshot.
  captureBaseline('capture_baseline'),

  /// Compare visual screen with baseline screenshot.
  compare('compare');

  /// The raw String identifier of the action.
  final String value;

  const ScreenshotAction(this.value);

  /// Resolves the action from a raw string.
  /// Throws an [ArgumentError] if the action is unsupported.
  static ScreenshotAction fromString(String val) {
    return ScreenshotAction.values.firstWhere(
      (e) => e.value.toLowerCase() == val.toLowerCase(),
      orElse: () => throw ArgumentError('Unsupported action: $val'),
    );
  }
}

/// The format/method used to capture screenshots.
enum ScreenshotType {
  /// Native device screenshot.
  device('device'),

  /// Skia Picture representation via VM service.
  skia('skia');

  /// The raw String identifier of the screenshot type.
  final String value;

  const ScreenshotType(this.value);

  /// Resolves the type from a raw string, defaulting to [device].
  static ScreenshotType fromString(String? val) {
    return ScreenshotType.values.firstWhere(
      (e) => e.value.toLowerCase() == val?.toLowerCase(),
      orElse: () => ScreenshotType.device,
    );
  }
}
