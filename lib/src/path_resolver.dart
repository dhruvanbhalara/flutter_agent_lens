import 'dart:io';
import 'package:path/path.dart' as p;

/// Maps VM-reported file URIs (such as `package:foo/main.dart` or `file://`) to local absolute paths.
final class PathResolver {
  /// Creates a new [PathResolver] instance centered around the given [workspaceRoot].
  PathResolver(this.workspaceRoot);

  /// The absolute path of the local Flutter workspace root.
  final String workspaceRoot;

  /// Cache mapping VM-reported URIs to resolved local absolute file paths.
  final Map<String, String> _pathCache = {};

  /// Cached dictionary of all files in the workspace (for fallback lookups).
  Map<String, String>? _allWorkspaceFiles;

  /// Resolves a VM-reported URI to a local absolute path.
  String resolveToAbsolutePath(String vmUri) {
    if (_pathCache.containsKey(vmUri)) {
      return _pathCache[vmUri]!;
    }

    // Skip fallback search for known system, internal or non-path URIs
    if (vmUri.startsWith('dart:') ||
        vmUri.startsWith('org-dartlang-') ||
        vmUri.startsWith('native') ||
        (!vmUri.startsWith('package:') &&
            !vmUri.startsWith('file://') &&
            !vmUri.contains('/'))) {
      _pathCache[vmUri] = vmUri;
      return vmUri;
    }

    var relativePath = vmUri;

    // 1. Convert package URIs: package:my_app/src/home.dart -> lib/src/home.dart
    if (vmUri.startsWith('package:')) {
      final parts = vmUri.replaceFirst('package:', '').split('/');
      if (parts.length > 1) {
        parts.removeAt(0); // Remove package namespace
        relativePath = p.joinAll(['lib', ...parts]);
      }
    }
    // 2. Convert standard file:// URIs
    else if (vmUri.startsWith('file://')) {
      final filePath = Uri.parse(vmUri).toFilePath();
      _pathCache[vmUri] = filePath;
      return filePath;
    }

    // 3. Resolve path relative to Workspace Root
    final resolvedPath = p.canonicalize(p.join(workspaceRoot, relativePath));
    if (File(resolvedPath).existsSync()) {
      _pathCache[vmUri] = resolvedPath;
      return resolvedPath;
    }

    // 4. Fallback search (For complex layouts / multi-module monorepos) using lazy cached files
    final fileName = p.basename(relativePath);
    if (_allWorkspaceFiles == null) {
      _allWorkspaceFiles = {};
      try {
        final directory = Directory(workspaceRoot);
        if (directory.existsSync()) {
          final entities =
              directory.listSync(recursive: true, followLinks: false);
          for (final entity in entities) {
            if (entity is File) {
              final filePath = entity.path;
              final separator = p.separator;
              if (filePath.contains('$separator.git$separator') ||
                  filePath.contains('$separator.dart_tool$separator') ||
                  filePath.contains('$separator.github$separator') ||
                  filePath.contains('$separator.idea$separator') ||
                  filePath.contains('$separator.vscode$separator') ||
                  filePath.contains('${separator}build$separator') ||
                  filePath.contains('${separator}node_modules$separator')) {
                continue;
              }
              final name = p.basename(filePath);
              _allWorkspaceFiles!
                  .putIfAbsent(name, () => p.canonicalize(filePath));
            }
          }
        }
      } catch (e) {
        stderr.writeln('[mcp:path_resolver] Error walking workspace: $e');
      }
    }

    final matchedPath = _allWorkspaceFiles![fileName];
    if (matchedPath != null) {
      _pathCache[vmUri] = matchedPath;
      return matchedPath;
    }

    // Return original URI as fallback if unmapped
    _pathCache[vmUri] = vmUri;
    return vmUri;
  }
}
