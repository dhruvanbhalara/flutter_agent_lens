import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Parses and caches package configurations from .dart_tool/package_config.json.
class WorkspacePackageResolver {
  /// Creates a resolver for the given [workspaceRoot] directory.
  WorkspacePackageResolver(this.workspaceRoot);

  /// Absolute path to the workspace root directory.
  final String workspaceRoot;
  final Set<String> _localPackages = {};
  final Set<String> _externalPackages = {};
  DateTime? _lastModified;

  /// Packages whose root directory resides inside [workspaceRoot].
  Set<String> get localPackages => Set.unmodifiable(_localPackages);

  /// Packages resolved to locations outside the workspace (pub-cache, SDK, etc.).
  Set<String> get externalPackages => Set.unmodifiable(_externalPackages);

  /// Adds a package name to the local packages set (primarily for testing).
  void addLocalPackage(String name) => _localPackages.add(name);

  /// Adds a package name to the external packages set (primarily for testing).
  void addExternalPackage(String name) => _externalPackages.add(name);

  /// Loads the package configuration from disk.
  Future<void> load() async {
    final configPath =
        p.join(workspaceRoot, '.dart_tool', 'package_config.json');
    final configFile = File(configPath);
    if (!configFile.existsSync()) return;

    try {
      final stat = configFile.statSync();
      if (_lastModified != null && !stat.modified.isAfter(_lastModified!)) {
        return;
      }
      _lastModified = stat.modified;

      final content = await configFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final packages = json['packages'] as List<dynamic>? ?? [];
      final canonicalRoot = p.canonicalize(workspaceRoot);
      final baseUri = Uri.file(p.join(workspaceRoot, '.dart_tool/'));

      _localPackages.clear();
      _externalPackages.clear();

      for (final pkg in packages) {
        if (pkg is! Map) continue;
        final name = pkg['name'] as String?;
        final rootUriStr = pkg['rootUri'] as String?;
        if (name == null || rootUriStr == null) continue;

        try {
          final resolvedUri = baseUri.resolve(rootUriStr);
          // toFilePath() throws UnsupportedError for non-file schemes.
          final absPath = resolvedUri.toFilePath();
          final canonicalPath = p.canonicalize(absPath);

          if (canonicalPath.startsWith(canonicalRoot)) {
            _localPackages.add(name);
          } else {
            _externalPackages.add(name);
          }
        } catch (_) {
          // Skip package if resolution fails
        }
      }
    } catch (_) {}
  }
}
