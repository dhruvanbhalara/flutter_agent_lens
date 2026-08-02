import 'dart:convert';
import 'dart:io';

/// A function signature matching [Process.run], used for dependency injection and testing.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment,
  bool runInShell,
  Encoding stdoutEncoding,
  Encoding stderrEncoding,
});
