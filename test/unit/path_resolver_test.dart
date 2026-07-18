import 'dart:io';

import 'package:flutter_agent_lens/src/path_resolver.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late PathResolver resolver;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('path_resolver_test_');
    resolver = PathResolver(tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('PathResolver Tests', () {
    test('resolve standard package URIs to workspace lib paths', () async {
      const packageUri = 'package:my_app/src/home.dart';
      final file = File(p.join(tempDir.path, 'lib', 'src', 'home.dart'));
      await file.create(recursive: true);
      final expectedPath = p.canonicalize(file.path);

      final resolved = await resolver.resolveToAbsolutePath(packageUri);
      expect(resolved, equals(expectedPath));
    });

    test('resolve standard file URIs directly', () async {
      final fileUri =
          Uri.file(p.join(tempDir.path, 'lib', 'main.dart')).toString();
      final expectedPath =
          p.canonicalize(p.join(tempDir.path, 'lib', 'main.dart'));

      final resolved = await resolver.resolveToAbsolutePath(fileUri);
      expect(resolved, equals(expectedPath));
    });

    test('system URIs return unchanged without resolving or scanning',
        () async {
      expect(await resolver.resolveToAbsolutePath('dart:core'),
          equals('dart:core'));
      expect(
        await resolver.resolveToAbsolutePath(
            'org-dartlang-sdk:///sdk/lib/core/core.dart'),
        equals('org-dartlang-sdk:///sdk/lib/core/core.dart'),
      );
      expect(await resolver.resolveToAbsolutePath('native'), equals('native'));
    });

    test('fallback search matches filename in workspace', () async {
      // Create a file nested deep in the temp directory
      final nestedDir = Directory(
          p.join(tempDir.path, 'packages', 'feature_a', 'lib', 'src'));
      await nestedDir.create(recursive: true);
      final file = File(p.join(nestedDir.path, 'widget.dart'));
      await file.writeAsString('// test');

      // Attempting to resolve widget.dart should hit the fallback search
      final resolved = await resolver
          .resolveToAbsolutePath('package:feature_a/src/widget.dart');
      expect(resolved, equals(p.canonicalize(file.path)));
    });

    test('cache eviction uses LRU semantics', () async {
      const packageUri = 'package:my_app/src/home.dart';
      final file = File(p.join(tempDir.path, 'lib', 'src', 'home.dart'));
      await file.create(recursive: true);
      final expectedPath = p.canonicalize(file.path);

      await resolver.resolveToAbsolutePath(packageUri);

      // Populate 999 other items in cache
      for (var i = 0; i < 999; i++) {
        await resolver.resolveToAbsolutePath('file:///dummy_$i.dart');
      }

      // Touch packageUri to promote it to MRU (most recently used)
      await resolver.resolveToAbsolutePath(packageUri);

      // Add one more to trigger eviction
      await resolver.resolveToAbsolutePath('file:///dummy_new.dart');

      // Delete the file from disk so that if it is a cache miss, it returns packageUri itself instead of resolved path
      await file.delete();

      // Since packageUri was promoted, it should still be in cache
      final resolved = await resolver.resolveToAbsolutePath(packageUri);
      expect(resolved, equals(expectedPath));
    });

    test('unicode path resolution', () async {
      const packageUri = 'package:my_app/src/日本語.dart';
      final file = File(p.join(tempDir.path, 'lib', 'src', '日本語.dart'));
      await file.create(recursive: true);
      final expectedPath = p.canonicalize(file.path);

      final resolved = await resolver.resolveToAbsolutePath(packageUri);
      expect(resolved, equals(expectedPath));
    });

    test('empty or invalid package URIs pass through or return default path',
        () async {
      expect(
          await resolver.resolveToAbsolutePath('package:'), equals('package:'));
      expect(await resolver.resolveToAbsolutePath('package:foo'),
          equals('package:foo'));
    });

    test('non-existent workspace root returns fallback', () async {
      final badResolver = PathResolver('/non_existent_directory_xyz');
      final resolved =
          await badResolver.resolveToAbsolutePath('package:foo/bar.dart');
      expect(resolved, equals('package:foo/bar.dart'));
    });

    test('directory walk terminates when file limit is reached', () async {
      final dir1 = Directory(p.join(tempDir.path, 'dir1'));
      await dir1.create();
      final dir2 = Directory(p.join(tempDir.path, 'dir2'));
      await dir2.create();

      // Create 10000 files in dir1
      for (var i = 0; i < 10000; i++) {
        File(p.join(dir1.path, 'file_$i.dart')).createSync();
      }

      // Resolving a file should scan and stop at 10,000 files
      final resolved =
          await resolver.resolveToAbsolutePath('package:nonexistent/file.dart');
      expect(resolved, equals('package:nonexistent/file.dart'));
    });
  });
}
