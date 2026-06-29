import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Represents a running Flutter or Dart application discovered on the local machine.
class DiscoveredApp {
  final String serviceUri;
  final String projectName;
  final String configPath;

  DiscoveredApp({
    required this.serviceUri,
    required this.projectName,
    required this.configPath,
  });
}

/// Finds running Flutter/Dart applications by scanning OS processes.
Future<List<DiscoveredApp>> discoverActiveApps() async {
  final apps = <DiscoveredApp>[];
  stderr.writeln('[discovery] Starting process-based app discovery...');

  try {
    if (Platform.isWindows) {
      final result = await Process.run('powershell', [
        '-Command',
        'Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like "*development-service*" } | Select-Object CommandLine, ProcessId, WorkingDirectory | ConvertTo-Json'
      ]);
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
      final vmUriPattern = RegExp(r'--vm-service-uri=(http://\S+)');

      for (final proc in processes) {
        if (proc is! Map) continue;
        final cmdLine = proc['CommandLine'] as String? ?? '';
        final pid = (proc['ProcessId'] ?? proc['Processid'] ?? '').toString();
        final workingDir = proc['WorkingDirectory'] as String? ?? '';

        final uriMatch = vmUriPattern.firstMatch(cmdLine);
        if (uriMatch == null) continue;

        final rawVmUri = uriMatch.group(1)!;
        final projectName = workingDir.isNotEmpty
            ? p.basename(workingDir)
            : 'Flutter App (pid $pid)';

        await _probeAndAddApp(
            rawVmUri, projectName, 'process scan (DDS pid $pid)', apps);
      }
    } else {
      final psResult = await Process.run('ps', ['aux']);
      if (psResult.exitCode != 0) {
        stderr.writeln('[discovery] ps command failed: ${psResult.exitCode}');
        return apps;
      }

      final lines = (psResult.stdout as String).split('\n');
      final vmUriPattern = RegExp(r'--vm-service-uri=(http://\S+)');
      final pidPattern = RegExp(r'^\S+\s+(\d+)');
      var ddsCount = 0;

      for (final line in lines) {
        if (!line.contains('development-service')) continue;
        ddsCount++;

        final uriMatch = vmUriPattern.firstMatch(line);
        final pidMatch = pidPattern.firstMatch(line);
        if (uriMatch == null || pidMatch == null) {
          stderr.writeln(
              '[discovery] DDS process found but could not parse: $line');
          continue;
        }

        final rawVmUri = uriMatch.group(1)!;
        final pid = pidMatch.group(1)!;
        stderr.writeln(
            '[discovery] Found DDS process pid=$pid, rawVmUri=$rawVmUri');

        // Get project name from the process's working directory.
        String projectName = 'Flutter App (pid $pid)';
        try {
          final cwdResult =
              await Process.run('lsof', ['-p', pid, '-Fn', '-d', 'cwd']);
          if (cwdResult.exitCode == 0) {
            final cwdLines = (cwdResult.stdout as String).split('\n');
            for (final cwdLine in cwdLines) {
              if (cwdLine.startsWith('n/')) {
                final cwdPath = cwdLine.substring(1);
                projectName = p.basename(cwdPath);
                stderr
                    .writeln('[discovery] Project name from cwd: $projectName');
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

Future<void> _probeAndAddApp(
  String rawVmUri,
  String projectName,
  String configPath,
  List<DiscoveredApp> apps,
) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    final request = await client.getUrl(Uri.parse(rawVmUri));
    request.followRedirects = false;
    final response = await request.close();
    final statusCode = response.statusCode;
    final location = response.headers.value('location') ?? '';
    client.close(force: true);

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
      final pathSegments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
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
  } catch (e) {
    stderr
        .writeln('[discovery] Failed to probe raw VM service at $rawVmUri: $e');
  }
}
