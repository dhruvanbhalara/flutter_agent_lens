import 'dart:convert';
import 'dart:io';

/// Injectable abstraction for executing system commands, allowing for testing.
class ProcessRunner {
  /// Creates a new [ProcessRunner] instance.
  const ProcessRunner();

  /// Runs the specified [executable] with [arguments] using [Process.run].
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding stdoutEncoding = systemEncoding,
    Encoding stderrEncoding = systemEncoding,
  }) {
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }
}
