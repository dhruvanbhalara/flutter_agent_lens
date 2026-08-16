# Flutter Agent Lens MCP Server

A Model Context Protocol (MCP) server that connects AI assistants to running Flutter applications. It communicates with the Dart VM Service over WebSockets, giving AI tools direct access to application state, performance data, layout constraints, and console logs.

---

## Features

AI assistants (such as Claude or Copilot) can inspect, profile, and debug any Flutter application running in debug or profile mode. You can use this server to:
- Track widget rebuild frequencies.
- Diagnose rendering bottlenecks and frame jank.
- Analyze CPU usage and execution hotspots.
- Audit memory usage and find retaining paths that cause memory leaks.
- Capture console, stdout, stderr, and logging streams.
- Read local build sizes to locate heavy packages and assets.
- Validate App Links and Universal Links configurations.
- Drive scroll behaviors and trigger hot reloads.

---

## Setup

### 1. Install the CLI
Activate the package globally to register the `flutter-agent-lens` binary:
```bash
dart pub global activate flutter_agent_lens
```
*Make sure your global pub cache bin directory is in your system PATH.*

### 2. Configure the MCP Client

#### Claude Desktop
Add this to your configuration file (macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`, Windows: `%APPDATA%\Claude\claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "flutter_agent_lens": {
      "command": "flutter-agent-lens"
    }
  }
}
```

#### Cursor
1. Go to **Settings** > **Features** > **MCP**.
2. Click **+ Add New MCP Server** and set:
   - **Name**: `flutter_agent_lens`
   - **Type**: `command`
   - **Command**: `flutter-agent-lens`

---

## Tool Catalog

This server groups functions into action-based tools to keep the schema footprint small.

### Connection & Setup (Pre-connection / Startup)

| Tool | Action Option | Description |
| :--- | :--- | :--- |
| `connection` | `connect`<br>`connectDtd`<br>`disconnect` | Connect to the VM Service, Dart Tooling Daemon (DTD), or disconnect. |
| `discover_apps` | *N/A* | Find running Flutter apps on this machine. |
| `diagnose_project` | `bundleSize`<br>`deepLinks` | Run local build size analysis or check platform deep links. |
| `set_response_format`| *N/A* | Choose output format (`markdown` or `json`). |

### Connected Tools (Requires Active Connection)

| Category | Tool | Actions / Subcommands | Description |
| :--- | :--- | :--- | :--- |
| **App Info** | `get_app_info` | *N/A* | Get VM version details, isolates, and service extensions. |
| **DTD Integration**| `get_active_location`| *N/A* | Find active editor path and cursor line (requires DTD). |
| **Memory** | `memory` | `getSnapshot`, `save`, `compare`, `list`, `auditLeak`, `diffAllocations`, `getReferrers`, `forceGc`, `startGcStream`, `stopGcStream`, `getMemoryTimeline`, `watchGcPressure`, `explainMemoryBreakdown` | Monitor heap, save snapshots, diff allocations, find memory leaks, trigger GC, stream GC events, sample memory timelines, and trace object references. |
| **Diagnostics** | `profiling` | `start`, `stop`, `getCpu`, `diagnoseJank` | Track render times, find CPU hotspots, and diagnose UI lag. |
| | `rebuild_tracking` | `start`, `stop`, `getCounts` | Track widget rebuild cycles and counts. |
| **Logs & Network** | `network` | `start`, `stop`, `getProfile`, `watch`, `getRequestDetails` | Capture HTTP network calls, stream requests over duration window, inspect headers and bodies. |
| | `console_logs` | `fetch`, `watch` | Read buffered console logs or stream live stdout/stderr/developer logs. |
| | `trigger_scroll_gesture` | *N/A* | Scroll the application viewport. |
| **Widget Inspector** | `widget` | `inspect`, `toggleSelection`, `getTree` | Find widget tree structure, get layout details, and toggle device inspector. |
| | `get_navigation_stack` | *N/A* | Inspect active Flutter Router and Navigator route tree, current URL, and depth. |
| | `debug_flag` | `toggle`, `togglePackageWidgets` | Change debug settings (e.g. paint size) or toggle package widget visibility. |
| **Screenshots** | `screenshot` | `take`, `captureBaseline`, `compare` | Take screen capture or run visual regression comparisons. |
| **Hot Reload** | `hot_reload` / `hot_restart`| *N/A* | Trigger hot reload or hot restart. |
| **Debugger** | `breakpoint` | `add`, `remove` | Add or remove code breakpoints. |
| | `get_call_stack` | *N/A* | Get active stack frames when application is paused. |
| | `set_exception_pause_mode`| *N/A* | Choose when to pause on exceptions. |
| | `evaluate_expression`| *N/A* | Run a Dart expression inside an isolate. |

### Tool Parameters Reference

#### `connection`
- `action` (required): `connect` | `connectDtd` | `disconnect`
- `uri`: WebSocket/HTTP URI of running debug target or DTD
- `workspaceRoot`: Absolute path to target Flutter project root directory
- `autoConnect`: boolean (default: `true`)
- `vmServiceUri`: string alias for VM Service URI

#### `discover_apps`
- `autoConnect`: boolean (default: `true`)
- `workspaceRoot`: Absolute path to target Flutter project root directory

#### `diagnose_project`
- `action` (required): `bundleSize` | `deepLinks`
- `buildTarget`: `apk` | `appbundle` | `ios` | `web` (default: `apk`)
- `targetPlatform`: string (e.g. `android-arm64`)
- `analysisPath`: string (optional path to size analysis JSON file)
- `platform`: `android` | `ios` (required for `deepLinks`)
- `buildVariant`: string (e.g. `release`, `debug`)
- `limit`: int (max entries, default: `25`)

#### `set_response_format`
- `format`: `markdown` | `json` (default: `markdown`)

#### `get_app_info`
- `includeExtensions`: boolean (default: `false`)

#### `memory`
- `action` (required): `getSnapshot` | `save` | `compare` | `list` | `auditLeak` | `diffAllocations` | `getReferrers` | `forceGc` | `startGcStream` | `stopGcStream` | `getMemoryTimeline` | `watchGcPressure` | `explainMemoryBreakdown`
- `className`: string (target class name for `auditLeak`)
- `objectId`: string (target VM object ID for `getReferrers`)
- `name`: string (snapshot label for `save`)
- `before`: string (baseline snapshot name for `compare`)
- `after`: string (target snapshot name for `compare`)
- `durationSeconds`: int (sample duration in seconds, default: `5`)
- `filterZeroDeltas`: boolean (filter out unchanged classes in `diffAllocations`, default: `false`)
- `expression`: string (optional Dart expression to evaluate during `diffAllocations`)
- `forceGc`: boolean (trigger GC before taking snapshot, default: `false`)
- `limit`: int (max results returned, default: `50`-`100`)
- `topN`: int (top classes limit, default: `20`)

#### `profiling`
- `action` (required): `start` | `stop` | `getCpu` | `diagnoseJank`
- `durationSeconds`: int (recording window in seconds, default: `5`)
- `limit`: int (max hotspots or jank frames returned, default: `15`)

#### `rebuild_tracking`
- `action` (required): `start` | `stop` | `getCounts`
- `durationSeconds`: int (tracking window in seconds)
- `excludeFlutterWidgets`: boolean (exclude built-in SDK widgets, default: `true`)
- `topN`: int (top rebuild entries limit, default: `30`)

#### `network`
- `action` (required): `start` | `stop` | `getProfile` | `watch` | `getRequestDetails`
- `durationSeconds`: int (watch duration in seconds, default: `5`)
- `slowThresholdMs`: int (threshold to flag slow requests in ms, default: `500`)
- `includeDetails`: boolean (include full request/response headers & bodies, default: `false`)
- `includeRawResponse`: boolean (include raw VM Service JSON response, default: `false`)
- `limit`: int (max requests returned, default: `30`)

#### `console_logs`
- `action` (required): `fetch` | `watch`
- `limit`: int (max log entries returned, default: `50`)
- `durationSeconds`: int (watch window in seconds, default: `5`)
- `filter`: string (optional text filter substring)

#### `widget`
- `action` (required): `inspect` | `toggleSelection` | `getTree`
- `enabled`: boolean (enable inspector mode for `toggleSelection`)
- `maxDepth`: int (max tree depth for `getTree`, default: `8`)
- `projectOnly`: boolean (filter out non-user-project widgets, default: `true`)

#### `trigger_scroll_gesture`
- `offset`: double (scroll delta in logical pixels, default: `300.0`)
- `axis`: `vertical` | `horizontal` (default: `vertical`)
- `scrollControllerExpression`: string (optional expression targeting specific ScrollController)

#### `debug_flag`
- `action` (required): `toggle` | `togglePackageWidgets`
- `flagName`: string (flag identifier, e.g. `debugPaintSizeEnabled`, `timeDilation`)
- `value`: string or boolean value (e.g. `'true'`, `'5.0'`)

#### `screenshot`
- `action` (required): `take` | `captureBaseline` | `compare`
- `baselineName`: string (baseline snapshot name for `captureBaseline` or `compare`)
- `screenshotType`: `device` | `skia` (default: `device`)
- `deviceId`: string (optional target device ID)
- `outputPath`: string (optional file destination path)
- `threshold`: double (similarity match threshold ratio, default: `0.98`)

#### `breakpoint`
- `action` (required): `add` | `remove`
- `filePath`: string (relative or absolute Dart file path)
- `line`: int (line number)
- `breakpointId`: string (breakpoint ID required for `remove`)

#### `get_call_stack`
- `limit`: int (max frames returned, default: `20`)

#### `set_exception_pause_mode`
- `mode` (required): `None` | `All` | `Unhandled`

#### `evaluate_expression`
- `expression` (required): string (Dart code snippet)
- `frameIndex`: int (optional stack frame index)

---

## Troubleshooting

### Connection Fails
- Ensure your Flutter application is running in debug or profile mode. Release builds disable the VM Service.
- Check that the port is accessible. If running on physical devices or emulators, you may need to map ports using ADB: `adb reverse tcp:8181 tcp:8181`.
- If `discover_apps` fails to connect, verify that your application has initialized the Dart Development Service (DDS). You can check by running `discover_apps` with `autoConnect: false` to list active endpoints.

### Layout File Path Mapping Fails
- When connecting via `connect`, ensure you provide the absolute path to your local Flutter project directory in the `workspaceRoot` argument. This allows the path resolver to match package references back to your local files.

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
