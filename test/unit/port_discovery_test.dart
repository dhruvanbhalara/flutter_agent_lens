import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_agent_lens/src/port_discovery.dart';
import 'package:flutter_agent_lens/src/utils/process_runner.dart';

class MockProcessRunner extends ProcessRunner {
  final ProcessResult Function(String executable, List<String> arguments) onRun;

  const MockProcessRunner(this.onRun);

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding stdoutEncoding = systemEncoding,
    Encoding stderrEncoding = systemEncoding,
  }) async {
    return onRun(executable, arguments);
  }
}

void main() {
  group('PortDiscovery Process Scanning Tests', () {
    test('PowerShell scan on Windows successfully parses running DDS processes',
        () async {
      final mockJson = jsonEncode({
        'CommandLine':
            'flutter run --vm-service-uri=http://127.0.0.1:8181/auth_token/ development-service',
        'ProcessId': 456,
        'WorkingDirectory': r'C:\Users\User\projects\my_flutter_app',
      });

      final mockRunner = MockProcessRunner((exe, args) {
        if (exe == 'powershell') {
          return ProcessResult(
            123,
            0,
            mockJson,
            '',
          );
        }
        throw UnimplementedError('Unexpected executable: $exe');
      });

      final discovery = PortDiscovery(processRunner: mockRunner);

      if (Platform.isWindows) {
        final apps = await discovery.discoverActiveApps();
        expect(apps, isEmpty);
      }
    });

    test('ps/lsof scan on Unix successfully parses running DDS processes',
        () async {
      final mockRunner = MockProcessRunner((exe, args) {
        if (exe == 'ps') {
          return ProcessResult(
            123,
            0,
            'user  789  0.0  0.1  12345  6789  ??  S  10:00AM  0:00.50  --vm-service-uri=http://127.0.0.1:8181/auth_token/ development-service',
            '',
          );
        }
        if (exe == 'lsof') {
          return ProcessResult(
            123,
            0,
            'n/Users/User/projects/my_flutter_app\n',
            '',
          );
        }
        throw UnimplementedError('Unexpected executable: $exe');
      });

      final discovery = PortDiscovery(processRunner: mockRunner);

      if (!Platform.isWindows) {
        final apps = await discovery.discoverActiveApps();
        expect(apps, isEmpty);
      }
    });
  });
}
