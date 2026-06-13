part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for analyzing Flutter app bundle sizes.
extension BundleHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleAnalyzeBundleSize(CallToolRequest req) async {
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

    String defaultTarget = 'apk';
    if (_vmService != null) {
      try {
        final vm = await _vmService!.getVM();
        final os = vm.operatingSystem?.toLowerCase();
        if (os == 'ios') {
          defaultTarget = 'ios';
        } else if (os == 'macos') {
          defaultTarget = 'macos';
        } else if (os == 'windows') {
          defaultTarget = 'windows';
        } else if (os == 'linux') {
          defaultTarget = 'linux';
        }
      } catch (_) {}
    }

    final target = req.arguments?['build_target'] as String? ?? defaultTarget;
    final targetPlatform = req.arguments?['target_platform'] as String? ??
        ((target == 'apk' || target == 'appbundle') ? 'android-arm64' : '');

    stderr.writeln(
        '[mcp:bundle_size] Analyzing bundle size, target=$target, platform=$targetPlatform');

    final buildDir = Directory(p.join(root, 'build'));
    if (!buildDir.existsSync()) {
      return CallToolResult(
        content: [
          TextContent(
              text: 'Build directory does not exist at ${buildDir.path}.')
        ],
        isError: true,
      );
    }

    bool isSizeFile(String filePath) {
      final name = p.basename(filePath).toLowerCase();
      final containsPattern = name.contains('code-size-details') ||
          name.contains('code-size-analysis');
      if (!containsPattern) return false;

      if (target == 'apk' || target == 'appbundle') {
        return name.contains('apk') ||
            name.contains('appbundle') ||
            name.contains('android');
      }
      return name.contains(target.toLowerCase());
    }

    File? sizeFile;
    final fileEntities = buildDir.listSync(recursive: true);
    for (final entity in fileEntities) {
      if (entity is File && isSizeFile(entity.path)) {
        sizeFile = entity;
        break;
      }
    }

    // Fallback: look for any code-size-details.json or code-size-analysis file if target match fails
    if (sizeFile == null) {
      for (final entity in fileEntities) {
        if (entity is File) {
          final name = p.basename(entity.path).toLowerCase();
          if (name.contains('code-size-details') ||
              name.contains('code-size-analysis')) {
            sizeFile = entity;
            break;
          }
        }
      }
    }

    if (sizeFile == null || !sizeFile.existsSync()) {
      return CallToolResult(
        content: [
          TextContent(
            text: 'No size analysis file found in the build directory.\n\n'
                'Please run the following command manually to generate the size analysis file, then try again:\n\n'
                '  flutter build $target --analyze-size ${targetPlatform.isNotEmpty ? "--target-platform=$targetPlatform" : ""}',
          )
        ],
        isError: true,
      );
    }

    stderr.writeln(
        '[mcp:bundle_size] Parsing size analysis file: ${sizeFile.path}');
    final rawJson = jsonDecode(await sizeFile.readAsString());
    if (rawJson is! Map<String, dynamic>) {
      return CallToolResult(
        content: [
          TextContent(
              text:
                  'Invalid size analysis file format: Root is not a JSON object.')
        ],
        isError: true,
      );
    }

    final leafComponents = <Map<String, dynamic>>[];

    void visit(Map<String, dynamic> node) {
      final name = (node['n'] ?? node['name'])?.toString() ?? 'unknown';
      final value = node['value'] ?? node['size'];

      final children = node['children'];
      if (children is List && children.isNotEmpty) {
        for (final child in children) {
          if (child is Map<String, dynamic>) {
            visit(child);
          }
        }
      } else if (value is num) {
        leafComponents.add({
          'name': name,
          'size_bytes': value.toInt(),
        });
      }
    }

    visit(rawJson);

    // Sort by size descending
    leafComponents.sort(
        (a, b) => (b['size_bytes'] as int).compareTo(a['size_bytes'] as int));

    final totalSizeBytes = leafComponents.fold<int>(
        0, (sum, item) => sum + (item['size_bytes'] as int));

    final md =
        StringBuffer('Code Size Analysis: ${p.basename(sizeFile.path)}\n\n');
    md.writeln(
        '- Total Calculated Size: ${(totalSizeBytes / 1024 / 1024).toStringAsFixed(2)} MB ($totalSizeBytes Bytes)');
    md.writeln();
    md.writeln('| Component | Size | Percentage |');
    md.writeln('| :--- | :--- | :--- |');

    for (final item in leafComponents.take(25)) {
      final bytes = item['size_bytes'] as int;
      final sizeStr = bytes > 1024 * 1024
          ? '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB'
          : '${(bytes / 1024).toStringAsFixed(2)} KB';
      final pct = totalSizeBytes > 0 ? (bytes / totalSizeBytes) * 100 : 0.0;
      md.writeln(
          '| `${item['name']}` | $sizeStr | ${pct.toStringAsFixed(2)}% |');
    }

    if (leafComponents.length > 25) {
      md.writeln('\n_...and ${leafComponents.length - 25} more components._');
    }

    return _serializeDualFormat(
      title: 'Application Bundle Size Details',
      markdownBody: md.toString(),
      structuredData: {
        'file_analyzed': sizeFile.path,
        'total_bytes': totalSizeBytes,
        'components': leafComponents,
      },
      format: req.arguments?['format'] as String?,
    );
  }
}
