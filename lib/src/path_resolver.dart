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

    String relativePath = vmUri;

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
      final directory = Directory(workspaceRoot);
      if (directory.existsSync()) {
        _scanDirectory(directory);
      }
    }

    final matchedPath = _allWorkspaceFiles![fileName];
    if (matchedPath != null) {
      _cachePath(vmUri, matchedPath);
      return matchedPath;
    }

    // Return original URI as fallback if unmapped
    _cachePath(vmUri, vmUri);
    return vmUri;
  }

  /// Recursively walks a directory, skipping large/unwanted system folders.
  void _scanDirectory(Directory dir) {
    try {
      final entities = dir.listSync(followLinks: false);
      for (final entity in entities) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          if (name == '.git' ||
              name == '.dart_tool' ||
              name == '.github' ||
              name == '.idea' ||
              name == '.vscode' ||
              name == 'build' ||
              name == 'node_modules') {
            continue;
          }
          _scanDirectory(entity);
        } else if (entity is File) {
          final name = p.basename(entity.path);
          _allWorkspaceFiles!
              .putIfAbsent(name, () => p.canonicalize(entity.path));
        }
      }
    } catch (e) {
      stderr.writeln(
          '[mcp:path_resolver] Error scanning directory ${dir.path}: $e');
    }
  }

  /// Caches a resolved URI path while enforcing a maximum cache size.
  void _cachePath(String key, String value) {
    if (_pathCache.length >= 1000) {
      final oldestKey = _pathCache.keys.first;
      _pathCache.remove(oldestKey);
    }
    _pathCache[key] = value;
  }
}
