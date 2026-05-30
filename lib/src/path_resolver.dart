import 'dart:io';
import 'package:path/path.dart' as p;

/// Maps VM-reported file URIs to local absolute paths.
class PathResolver {
  final String workspaceRoot;
  final Map<String, String> _pathCache = {};

  PathResolver(this.workspaceRoot);

  /// Resolves a VM-reported URI to a local absolute path.
  String resolveToAbsolutePath(String vmUri) {
    if (_pathCache.containsKey(vmUri)) {
      return _pathCache[vmUri]!;
    }

    String relativePath = vmUri;

    // 1. Convert package URIs: package:my_app/src/home.dart -> lib/src/home.dart
    if (vmUri.startsWith('package:')) {
      final parts = vmUri.replaceFirst('package:', '').split('/');
      if (parts.length > 1) {
        parts.removeAt(0); // Remove package namespace
        relativePath = p.join('lib', parts.join('/'));
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

    // 4. Fallback search (For complex layouts / multi-module monorepos)
    final fileName = p.basename(relativePath);
    try {
      final directory = Directory(workspaceRoot);
      if (directory.existsSync()) {
        final matches = directory
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => p.basename(file.path) == fileName);

        if (matches.isNotEmpty) {
          final absolutePath = p.canonicalize(matches.first.path);
          _pathCache[vmUri] = absolutePath;
          return absolutePath;
        }
      }
    } catch (_) {}

    // Return original URI as fallback if unmapped
    return vmUri;
  }
}
