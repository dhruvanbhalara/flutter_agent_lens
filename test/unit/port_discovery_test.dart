import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_lens/src/port_discovery.dart';
import 'package:flutter_agent_lens/src/utils/process_runner.dart';
import 'package:test/test.dart';

class MockProcessRunner implements ProcessRunner {
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

class FakeHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return FakeHttpClientRequest();
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeHttpClientRequest implements HttpClientRequest {
  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async {
    return FakeHttpClientResponse();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeHttpClientResponse implements HttpClientResponse {
  @override
  int get statusCode => 302;

  @override
  HttpHeaders get headers => FakeHttpHeaders();

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return const Stream<List<int>>.empty().listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeHttpHeaders implements HttpHeaders {
  @override
  String? value(String name) {
    if (name == 'location') {
      return 'http://127.0.0.1:8181/auth_token/ws?uri=ws://127.0.0.1:8181/auth_token/ws';
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return FakeHttpClient();
  }
}

void main() {
  setUpAll(() {
    HttpOverrides.global = TestHttpOverrides();
  });

  tearDownAll(() {
    HttpOverrides.global = null;
  });

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
        expect(apps, isNotEmpty);
        expect(apps.first.projectName, equals('my_flutter_app'));
        expect(
            apps.first.serviceUri, equals('ws://127.0.0.1:8181/auth_token/ws'));
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
        expect(apps, isNotEmpty);
        expect(apps.first.projectName, equals('my_flutter_app'));
        expect(
            apps.first.serviceUri, equals('ws://127.0.0.1:8181/auth_token/ws'));
      }
    });
  });
}
