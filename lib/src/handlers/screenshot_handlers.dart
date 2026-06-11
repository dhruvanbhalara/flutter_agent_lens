part of '../../flutter_agent_lens.dart';

/// Extension containing handlers for capturing and comparing layout screenshots.
extension ScreenshotHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleCompareLayoutScreenshots(
      CallToolRequest req) async {
    final root = _workspaceRoot;
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
    final action = req.arguments!['action'] as String;
    final threshold = (req.arguments?['threshold'] as num?)?.toDouble() ?? 0.98;
    final screenshotType =
        req.arguments?['screenshot_type'] as String? ?? 'device';
    final deviceId = req.arguments?['device_id'] as String?;

    if (action != 'capture_baseline' && action != 'compare') {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Invalid action. Supported actions: capture_baseline, compare.')
        ],
        isError: true,
      );
    }
    if (screenshotType != 'device' && screenshotType != 'skia') {
      return CallToolResult(
        content: [
          TextContent(
              text: 'Invalid screenshot_type. Supported values: device, skia.')
        ],
        isError: true,
      );
    }

    stderr.writeln(
        '[mcp:screenshot] Action=$action, baselineName=$baselineName, type=$screenshotType, deviceId=$deviceId');

    final screenshotDir = Directory(p.join(root, 'build', 'mcp_screenshots'));
    if (!screenshotDir.existsSync()) {
      screenshotDir.createSync(recursive: true);
    }

    if (action == 'capture_baseline') {
      final baselinePath =
          p.join(screenshotDir.path, '${baselineName}_baseline.png');
      stderr.writeln('[mcp:screenshot] Capturing baseline to $baselinePath');

      try {
        final actualType = await _captureDeviceScreenshot(
          targetPath: baselinePath,
          screenshotType: screenshotType,
          deviceId: deviceId,
        );
        final notice = (screenshotType == 'skia' && actualType == 'device')
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
      // Compare action
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
          screenshotType: screenshotType,
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
            // Mark difference in bright red
            diffImage.setPixel(x, y, img.ColorRgba8(255, 0, 0, 255));
          }
        }
      }

      final similarity = matchingPixels / totalPixels;
      final passed = similarity >= threshold;

      stderr.writeln('[mcp:screenshot] Saving diff image to $diffPath');
      await File(diffPath).writeAsBytes(img.encodePng(diffImage));

      final md =
          StringBuffer('### Layout Screenshot Comparison: `$baselineName`\n\n');
      md.writeln('- **Status**: ${passed ? "PASS" : "FAIL"}');
      md.writeln(
          '- **Similarity Score**: ${(similarity * 100).toStringAsFixed(2)}% (Threshold: ${(threshold * 100).toStringAsFixed(2)}%)');
      md.writeln('- **Matching Pixels**: $matchingPixels / $totalPixels');
      if (screenshotType == 'skia' && actualType == 'device') {
        md.writeln(
            '- **Notice**: Automatically fell back to native "device" screenshot because Impeller is active and Skia is unsupported.');
      }
      md.writeln();
      md.writeln('#### Files Generated:');
      md.writeln('- Baseline: `$baselinePath`');
      md.writeln('- Current: `$currentPath`');
      md.writeln('- Visual Diff: `$diffPath`');

      return _serializeDualFormat(
        title: '### Visual Layout Comparison Report',
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

  Future<CallToolResult> _handleTakeScreenshot(CallToolRequest req) async {
    final root = _workspaceRoot;
    if (root == null || root.isEmpty) {
      return CallToolResult(
        content: [
          TextContent(
              text: 'Workspace root is not configured. Run connect first.')
        ],
        isError: true,
      );
    }

    final screenshotType =
        req.arguments?['screenshot_type'] as String? ?? 'device';
    final deviceId = req.arguments?['device_id'] as String?;
    final outputPath = req.arguments?['output_path'] as String?;

    if (screenshotType != 'device' && screenshotType != 'skia') {
      return CallToolResult(
        content: [
          TextContent(
              text: 'Invalid screenshot_type. Supported values: device, skia.')
        ],
        isError: true,
      );
    }

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
      screenshotType: screenshotType,
      deviceId: deviceId,
    );
    final notice = (screenshotType == 'skia' && actualType == 'device')
        ? '\n(Note: Automatically fell back to native "device" screenshot because Impeller is active and Skia is unsupported)'
        : '';
    return CallToolResult(
      content: [
        TextContent(text: 'Screenshot saved to $targetPath$notice'),
      ],
    );
  }

  Future<String> _captureDeviceScreenshot({
    required String targetPath,
    required String screenshotType,
    required String? deviceId,
  }) async {
    if (_vmService != null) {
      String? effectiveDeviceId = deviceId;
      String? os;

      try {
        final vm = await _vmService!.getVM();
        os = vm.operatingSystem?.toLowerCase();

        // 1. Auto-detect device ID if not explicitly passed
        if (effectiveDeviceId == null || effectiveDeviceId.isEmpty) {
          if (os != null) {
            effectiveDeviceId = await _detectDeviceForOs(os);
          }
        }
      } catch (_) {}

      // 2. Capture using flutter screenshot directly
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      final executable = flutterRoot != null
          ? p.join(flutterRoot, 'bin',
              Platform.isWindows ? 'flutter.bat' : 'flutter')
          : (Platform.isWindows ? 'flutter.bat' : 'flutter');

      final args = [
        'screenshot',
        '--out=$targetPath',
        if (screenshotType == 'skia' && _vmServiceUri != null) ...[
          '--vm-service-url=$_vmServiceUri',
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

  /// Auto-detect the connected device corresponding to the running app's operating system.
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

          if (normalizedOs == 'android') {
            return platform.startsWith('android');
          } else if (normalizedOs == 'ios') {
            return platform.startsWith('ios');
          } else if (normalizedOs == 'macos') {
            return platform == 'darwin' || id == 'macos';
          } else if (normalizedOs == 'windows') {
            return platform == 'windows' || id == 'windows';
          } else if (normalizedOs == 'linux') {
            return platform == 'linux' || id == 'linux';
          } else if (normalizedOs == 'web') {
            return platform == 'web-javascript' || id == 'chrome';
          }
          return false;
        }

        final matchesList =
            devices.whereType<Map<String, dynamic>>().where(matches).toList();

        if (matchesList.isNotEmpty) {
          // Prefer emulators/simulators if multiple found
          final emulator = matchesList.firstWhere(
            (d) => d['emulator'] == true,
            orElse: () => matchesList.first,
          );
          return emulator['id'] as String?;
        }
      }
    } catch (_) {}
    return null;
  }
}
