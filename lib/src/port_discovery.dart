import 'dart:convert';
import 'dart:io';

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
///
/// How it works:
///   1. Parse `ps aux` for DDS (Dart Development Service) processes.
///   2. Each DDS process has `--vm-service-uri=http://HOST:PORT/TOKEN=/`
///      pointing to the raw VM Service.
///   3. Hit that raw VM Service URI with HTTP (no redirects).
///      The response is a 302 redirect whose `Location` header contains
///      the DevTools URL, which includes `?uri=ws://HOST:DDS_PORT/DDS_TOKEN/ws`.
///   4. Extract the `uri` query parameter — that's the fully authenticated
///      DDS WebSocket URI we need.
Future<List<DiscoveredApp>> discoverActiveApps() async {
  final apps = <DiscoveredApp>[];
  stderr.writeln('[discovery] Starting process-based app discovery...');

  try {
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
              projectName = cwdPath.split('/').last;
              stderr.writeln('[discovery] Project name from cwd: $projectName');
              break;
            }
          }
        }
      } catch (e) {
        stderr.writeln('[discovery] Failed to get cwd for pid $pid: $e');
      }

      // Hit the raw VM Service URI to get a 302 redirect.
      // The redirect's Location header contains the DDS URI like:
      //   http://HOST:DDS_PORT/DDS_TOKEN/devtools/?uri=ws://HOST:DDS_PORT/DDS_TOKEN/ws
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 3);

        stderr.writeln('[discovery] Probing raw VM service at $rawVmUri');
        final request = await client.getUrl(Uri.parse(rawVmUri));
        request.followRedirects = false;
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final statusCode = response.statusCode;
        final location = response.headers.value('location') ?? '';
        client.close(force: true);

        stderr.writeln(
            '[discovery] Response: status=$statusCode, location=$location, body=${body.substring(0, body.length.clamp(0, 200))}');

        if (statusCode == 302 && location.isNotEmpty) {
          // Parse the uri query parameter from the Location header.
          final locationUri = Uri.parse(location);
          final wsUriParam = locationUri.queryParameters['uri'];

          if (wsUriParam != null && wsUriParam.isNotEmpty) {
            stderr.writeln(
                '[discovery] Extracted DDS WebSocket URI: $wsUriParam');
            apps.add(DiscoveredApp(
              serviceUri: wsUriParam,
              projectName: projectName,
              configPath: 'process scan (DDS pid $pid)',
            ));
          } else {
            // If no uri query parameter, construct from the redirect path.
            // Location format: http://HOST:DDS_PORT/DDS_TOKEN/devtools/...
            final locPath = locationUri.path;
            final pathSegments =
                locPath.split('/').where((s) => s.isNotEmpty).toList();
            if (pathSegments.isNotEmpty) {
              final ddsToken = pathSegments.first;
              final ddsPort = locationUri.port;
              final ddsHost = locationUri.host;
              final wsUri = 'ws://$ddsHost:$ddsPort/$ddsToken/ws';
              stderr.writeln(
                  '[discovery] Constructed DDS WebSocket URI from redirect path: $wsUri');
              apps.add(DiscoveredApp(
                serviceUri: wsUri,
                projectName: projectName,
                configPath: 'process scan (DDS pid $pid)',
              ));
            }
          }
        } else if (statusCode == 200) {
          // Some configurations don't redirect. Try connecting to the raw URI directly.
          final uri = Uri.parse(rawVmUri);
          final pathSegments =
              uri.pathSegments.where((s) => s.isNotEmpty).toList();
          final authToken = pathSegments.isNotEmpty ? pathSegments.first : '';
          final wsUri = 'ws://${uri.host}:${uri.port}/$authToken/ws';
          stderr.writeln(
              '[discovery] No redirect, trying raw VM URI directly: $wsUri');
          apps.add(DiscoveredApp(
            serviceUri: wsUri,
            projectName: projectName,
            configPath: 'process scan (raw VM, pid $pid)',
          ));
        } else {
          stderr.writeln(
              '[discovery] Unexpected response from raw VM service: status=$statusCode');
        }
      } catch (e) {
        stderr.writeln(
            '[discovery] Failed to probe raw VM service at $rawVmUri: $e');
      }
    }

    stderr.writeln(
        '[discovery] Scanned $ddsCount DDS processes, found ${apps.length} app(s)');
  } catch (e) {
    stderr.writeln('[discovery] Process scan failed: $e');
  }

  return apps;
}
