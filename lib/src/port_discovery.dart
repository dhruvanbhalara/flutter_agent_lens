import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_lens/src/utils/process_runner.dart';
import 'package:path/path.dart' as p;

/// Represents a running Flutter or Dart application discovered on the local machine.
final class DiscoveredApp {
  /// Creates a new [DiscoveredApp] instance.
  const DiscoveredApp({
    required this.serviceUri,
    required this.projectName,
    required this.configPath,
  });

  /// The WebSocket VM Service URI of the application (e.g. `ws://127.0.0.1:8181/auth_token/ws`).
  final String serviceUri;

  /// The name of the project corresponding to the application's working directory.
  final String projectName;

  /// A descriptive identifier indicating how this app was discovered.
  final String configPath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredApp &&
          other.serviceUri == serviceUri &&
          other.projectName == projectName &&
          other.configPath == configPath;

  @override
  int get hashCode => Object.hash(serviceUri, projectName, configPath);

  @override
  String toString() => 'DiscoveredApp(project: $projectName, uri: $serviceUri)';
}

/// Finds running Flutter/Dart applications by scanning OS processes.
///
/// Under Windows, it uses PowerShell to query CIM instances. On macOS and Linux,
/// it executes `ps` and maps the process working directories.
Future<List<DiscoveredApp>> discoverActiveApps() {
  if (Platform.environment.containsKey('FLUTTER_TEST') ||
      Platform.script.path.contains('/test/') ||
      Platform.script.path.contains('test.dart')) {
    return Future.value(<DiscoveredApp>[]);
  }
  return const PortDiscovery().discoverActiveApps();
}

/// Discovers running Flutter/Dart applications using process queries and HTTP probing.
class PortDiscovery {
  /// The command runner helper, allowing test mocks.
  final ProcessRunner processRunner;

  /// Creates a new [PortDiscovery] instance.
  const PortDiscovery({this.processRunner = const DefaultProcessRunner()});

  static final RegExp _vmUriPattern = RegExp(r'--vm-service-uri=(http://\S+)');
  static final RegExp _pidPattern = RegExp(r'^\S+\s+(\d+)');

  String _sanitizeUri(String rawUri) {
    final parsed = Uri.tryParse(rawUri);
    if (parsed == null) return '<malformed URI>';
    return '${parsed.scheme}://${parsed.host}:${parsed.port}/<redacted>';
  }

  /// Finds running Flutter/Dart applications by scanning OS processes.
  Future<List<DiscoveredApp>> discoverActiveApps() async {
    final apps = <DiscoveredApp>[];
    stderr.writeln('[discovery] Starting process-based app discovery...');

    try {
      if (Platform.isWindows) {
        final result = await processRunner.run('powershell', [
          '-Command',
          r'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*development-service*" } | Select-Object CommandLine, ProcessId, WorkingDirectory | ConvertTo-Json'
        ]).timeout(const Duration(seconds: 5));

        if (result.exitCode != 0) {
          stderr.writeln(
              '[discovery] PowerShell command failed: ${result.exitCode}');
          return apps;
        }

        final rawJson = result.stdout.toString().trim();
        if (rawJson.isEmpty) return apps;

        dynamic decoded;
        try {
          decoded = jsonDecode(rawJson);
        } catch (e) {
          stderr.writeln('[discovery] Failed to decode PowerShell JSON: $e');
          return apps;
        }

        final List<dynamic> processes = decoded is List ? decoded : [decoded];

        for (final proc in processes) {
          if (proc is! Map) continue;
          final cmdLine = proc['CommandLine'] as String? ?? '';
          final pid = (proc['ProcessId'] ?? proc['Processid'] ?? '').toString();
          final workingDir = proc['WorkingDirectory'] as String? ?? '';

          final uriMatch = _vmUriPattern.firstMatch(cmdLine);
          if (uriMatch == null) continue;

          final rawVmUri = uriMatch.group(1)!;
          final projectName = workingDir.isNotEmpty
              ? p.basename(workingDir)
              : 'Flutter App (pid $pid)';

          await _probeAndAddApp(
              rawVmUri, projectName, 'process scan (DDS pid $pid)', apps);
        }
      } else {
        final psResult = await processRunner
            .run('ps', ['aux']).timeout(const Duration(seconds: 5));
        if (psResult.exitCode != 0) {
          stderr.writeln('[discovery] ps command failed: ${psResult.exitCode}');
          return apps;
        }

        final lines = psResult.stdout.toString().split('\n');
        var ddsCount = 0;

        for (final line in lines) {
          if (!line.contains('development-service')) continue;
          ddsCount++;

          final uriMatch = _vmUriPattern.firstMatch(line);
          final pidMatch = _pidPattern.firstMatch(line);
          if (uriMatch == null || pidMatch == null) {
            final sanitizedLine =
                line.replaceAll(_vmUriPattern, '--vm-service-uri=<redacted>');
            stderr.writeln(
                '[discovery] DDS process found but could not parse: $sanitizedLine');
            continue;
          }

          final rawVmUri = uriMatch.group(1)!;
          final pid = pidMatch.group(1)!;
          final sanitizedVmUri = _sanitizeUri(rawVmUri);
          stderr.writeln(
              '[discovery] Found DDS process pid=$pid, rawVmUri=$sanitizedVmUri');

          // Get project name from the process's working directory.
          String projectName = 'Flutter App (pid $pid)';
          try {
            final cwdResult = await processRunner
                .run('lsof', ['-p', pid, '-Fn', '-d', 'cwd']).timeout(
                    const Duration(seconds: 3));
            if (cwdResult.exitCode == 0) {
              final cwdLines = (cwdResult.stdout as String).split('\n');
              for (final cwdLine in cwdLines) {
                if (cwdLine.startsWith('n/')) {
                  final cwdPath = cwdLine.substring(1);
                  projectName = p.basename(cwdPath);
                  stderr.writeln(
                      '[discovery] Project name from cwd: $projectName');
                  break;
                }
              }
            }
          } catch (e) {
            stderr.writeln('[discovery] Failed to get cwd for pid $pid: $e');
          }

          await _probeAndAddApp(
              rawVmUri, projectName, 'process scan (DDS pid $pid)', apps);
        }
        stderr.writeln(
            '[discovery] Scanned $ddsCount DDS processes, found ${apps.length} app(s)');
      }
    } catch (e) {
      stderr.writeln('[discovery] Process scan failed: $e');
    }

    return apps;
  }

  /// Probes the given HTTP VM Service URI to verify if it is alive and
  /// extracts its WebSocket URL, appending it to the [apps] collection.
  Future<void> _probeAndAddApp(
    String rawVmUri,
    String projectName,
    String configPath,
    List<DiscoveredApp> apps,
  ) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(Uri.parse(rawVmUri));
      request.followRedirects = false;
      final response = await request.close();
      final statusCode = response.statusCode;
      final location = response.headers.value('location') ?? '';

      if (statusCode == 302 && location.isNotEmpty) {
        final locationUri = Uri.parse(location);
        final wsUriParam = locationUri.queryParameters['uri'];
        if (wsUriParam != null && wsUriParam.isNotEmpty) {
          apps.add(DiscoveredApp(
            serviceUri: wsUriParam,
            projectName: projectName,
            configPath: configPath,
          ));
        } else {
          final locPath = locationUri.path;
          final pathSegments =
              locPath.split('/').where((s) => s.isNotEmpty).toList();
          if (pathSegments.isNotEmpty) {
            final ddsToken = pathSegments.first;
            final ddsPort = locationUri.port;
            final ddsHost = locationUri.host;
            final wsUri = 'ws://$ddsHost:$ddsPort/$ddsToken/ws';
            apps.add(DiscoveredApp(
              serviceUri: wsUri,
              projectName: projectName,
              configPath: configPath,
            ));
          }
        }
      } else if (statusCode == 200) {
        final uri = Uri.parse(rawVmUri);
        final pathSegments =
            uri.pathSegments.where((s) => s.isNotEmpty).toList();
        final authToken = pathSegments.isNotEmpty ? pathSegments.first : '';
        final wsUri = 'ws://${uri.host}:${uri.port}/$authToken/ws';
        apps.add(DiscoveredApp(
          serviceUri: wsUri,
          projectName: projectName,
          configPath: configPath,
        ));
      } else {
        stderr.writeln(
            '[discovery] Unexpected response from raw VM service: status=$statusCode');
      }

      // Drain response body to prevent socket leakage
      try {
        await response.drain<void>();
      } catch (_) {}
    } catch (e) {
      final sanitizedVmUri = _sanitizeUri(rawVmUri);
      stderr.writeln(
          '[discovery] Failed to probe raw VM service at $sanitizedVmUri: $e');
    } finally {
      client.close(force: true);
    }
  }
}
