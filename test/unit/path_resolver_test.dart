import 'dart:io';
import 'package:flutter_agent_lens/src/path_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late PathResolver resolver;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('path_resolver_test');
    resolver = PathResolver(tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('PathResolver', () {
    test('passes system/internal/non-path URIs through unchanged', () {
      expect(resolver.resolveToAbsolutePath('dart:core'), equals('dart:core'));
      expect(resolver.resolveToAbsolutePath('org-dartlang-sdk:///sdk.dart'),
          equals('org-dartlang-sdk:///sdk.dart'));
      expect(resolver.resolveToAbsolutePath('native'), equals('native'));
    });

    test('resolves file:// URIs using Uri.toFilePath()', () {
      final fileUri =
          Uri.file(p.join(tempDir.path, 'lib/main.dart')).toString();
      final expectedPath = Uri.parse(fileUri).toFilePath();
      expect(resolver.resolveToAbsolutePath(fileUri), equals(expectedPath));
    });

    test('resolves package URIs to lib/ paths relative to workspaceRoot',
        () async {
      // Create lib/src/home.dart
      final homeFile = File(p.join(tempDir.path, 'lib', 'src', 'home.dart'));
      await homeFile.create(recursive: true);

      final result =
          resolver.resolveToAbsolutePath('package:my_app/src/home.dart');
      expect(result, equals(p.canonicalize(homeFile.path)));
    });

    test('falls back to searching files in workspace for complex layouts',
        () async {
      // Create deep file
      final nestedFile =
          File(p.join(tempDir.path, 'sub_package', 'lib', 'utils.dart'));
      await nestedFile.create(recursive: true);

      final result =
          resolver.resolveToAbsolutePath('some_other_package/lib/utils.dart');
      expect(result, equals(p.canonicalize(nestedFile.path)));
    });

    test('skips build, .git, and node_modules in workspace walk', () async {
      // Create files in ignored directories
      final gitFile = File(p.join(tempDir.path, '.git', 'config'));
      final buildFile = File(p.join(tempDir.path, 'build', 'web', 'main.dart'));
      final nodeModulesFile =
          File(p.join(tempDir.path, 'node_modules', 'lodash', 'index.js'));

      await gitFile.create(recursive: true);
      await buildFile.create(recursive: true);
      await nodeModulesFile.create(recursive: true);

      expect(
          resolver.resolveToAbsolutePath('pkg/config'), equals('pkg/config'));
      expect(resolver.resolveToAbsolutePath('pkg/main.dart'),
          equals('pkg/main.dart'));
      expect(resolver.resolveToAbsolutePath('pkg/index.js'),
          equals('pkg/index.js'));
    });

    test('caches resolved paths', () async {
      final homeFile = File(p.join(tempDir.path, 'lib', 'src', 'home.dart'));
      await homeFile.create(recursive: true);

      final result1 =
          resolver.resolveToAbsolutePath('package:my_app/src/home.dart');
      // Delete the file to verify it doesn't try to look it up on disk again
      await homeFile.delete();

      final result2 =
          resolver.resolveToAbsolutePath('package:my_app/src/home.dart');
      expect(result2, equals(result1));
    });
  });
}
