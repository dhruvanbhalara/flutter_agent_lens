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
| `connection` | `connect`<br>`connect_dtd`<br>`disconnect` | Connect to the VM Service, Dart Tooling Daemon (DTD), or disconnect. |
| `discover_apps` | *N/A* | Find running Flutter apps on this machine. |
| `diagnose_project` | `bundle_size`<br>`deep_links` | Run local build size analysis or check platform deep links. |
| `set_response_format`| *N/A* | Choose output format (`markdown` or `json`). |

### Connected Tools (Requires Active Connection)

| Category | Tool | Actions / Subcommands | Description |
| :--- | :--- | :--- | :--- |
| **App Info** | `get_app_info` | *N/A* | Get VM version details, isolates, and service extensions. |
| **DTD Integration**| `get_active_location`| *N/A* | Find active editor path and cursor line (requires DTD). |
| **Memory** | `memory` | `get_snapshot`, `save`, `compare`, `list`, `audit_leak`, `diff_allocations`, `get_referrers`, `force_gc`, `start_gc_stream`, `stop_gc_stream`, `get_memory_timeline`, `watch_gc_pressure`, `explain_memory_breakdown` | Monitor heap, save snapshots, diff allocations, find memory leaks, trigger GC, stream GC events, sample memory timelines, and trace object references. |
| **Diagnostics** | `profiling` | `start`, `stop`, `get_cpu`, `diagnose_jank` | Track render times, find CPU hotspots, and diagnose UI lag. |
| | `rebuild_tracking` | `start`, `stop`, `get_counts` | Track widget rebuild cycles and counts. |
| **Logs & Network** | `network` | `start`, `stop`, `get_profile`, `watch`, `get_request_details` | Capture HTTP network calls, stream requests over duration window, inspect headers and bodies. |
| | `console_logs` | `fetch`, `watch` | Read buffered console logs or stream live stdout/stderr/developer logs. |
| | `trigger_scroll_gesture` | *N/A* | Scroll the application viewport. |
| **Widget Inspector** | `widget` | `inspect`, `toggle_selection`, `get_tree` | Find widget tree structure, get layout details, and toggle device inspector. |
| | `get_navigation_stack` | *N/A* | Inspect active Flutter Router and Navigator route tree, current URL, and depth. |
| | `debug_flag` | `toggle`, `toggle_package_widgets` | Change debug settings (e.g. paint size) or toggle package widget visibility. |
| **Screenshots** | `screenshot` | `take`, `capture_baseline`, `compare` | Take screen capture or run visual regression comparisons. |
| **Hot Reload** | `hot_reload` / `hot_restart`| *N/A* | Trigger hot reload or hot restart. |
| **Debugger** | `breakpoint` | `add`, `remove` | Add or remove code breakpoints. |
| | `get_call_stack` | *N/A* | Get active stack frames when application is paused. |
| | `set_exception_pause_mode`| *N/A* | Choose when to pause on exceptions. |
| | `evaluate_expression`| *N/A* | Run a Dart expression inside an isolate. |

### Configurable Parameters & Options

To keep payloads light, these settings are supported:

- **Limits (`limit` / `topN`)**:
  - `limit` in `diagnose_project` (action: `deep_links`): Sets max deep links checked.
  - `limit` in `network` (action: `get_profile`): Sets the max HTTP requests returned (default: `30`).
  - `limit` in `profiling` (action: `diagnose_jank`): Sets max frames returned (default: `15`).
  - `limit` in `profiling` (action: `get_cpu`): Sets max CPU hotspots returned (default: `15`).
  - `limit` in `diagnose_project` (action: `bundle_size`): Sets max components shown (default: `25`).
  - `limit` in `memory` (action: `audit_leak`, `get_referrers`, `stop_gc_stream`, `watch_gc_pressure`): Sets max instances, path depth, or returned GC events (default: `50`-`100`).
  - `limit` in `console_logs` (action: `fetch`): Sets max buffered log entries returned (default: `50`, max: `500`).
  - `limit` in `get_call_stack`: Sets max stack frames returned (default: `20`).
  - `limit` in `console_logs` (action: `fetch`): Sets max buffered log entries returned (default: `50`, max: `500`).
  - `limit` in `get_call_stack`: Sets max stack frames returned (default: `20`).
  - `duration_seconds` in `console_logs` (`watch`), `network` (`watch`), `memory` (`get_memory_timeline`, `watch_gc_pressure`): Sets sampling or monitoring duration in seconds (default: `5.0`, max: `30`).
  - `slow_threshold_ms` in `network` (action: `watch`): Threshold in ms to flag slow requests (default: `500`).
  - `filter` in `console_logs` (action: `watch`): Optional text filter substring for live logs.
  - `topN` in `memory` (action: `compare`): Sets max class differences returned (default: `10`).
  - `topN` in `memory` (action: `get_snapshot`): Sets max classes by size (default: `20`).
  - `topN` in `rebuild_tracking` (action: `stop` / `get_counts`): Sets max rebuild entries shown (default: `30`).


- **Layout Controls**:
  - `maxDepth` in `widget` (action: `get_tree`): Sets widget tree depth (default: `8`).
  - `projectOnly` in `widget` (action: `get_tree`): Filters out non-user-project widgets (default: `true`).
  - `exclude_flutter_widgets` in `rebuild_tracking` (action: `stop` / `get_counts`): Excludes built-in Flutter/SDK and dependency widgets from the rebuild list (default: `true`).

- **Platform Settings**:
  - `platform` in `diagnose_project` (action: `deep_links`): Platform target (e.g. `android` or `ios`, required).

- **Payload & Token Optimization**:
  - `full` across all tools: When `true`, disables default token-saving safety shields (such as markdown truncation and collection compaction) to return complete, untruncated outputs (default: `false`).
  - `max_body_length` in `network` (action: `get_request_details`): Sets max character length for request/response bodies before truncation (default: `5000`, max: `50000`).
  - `include_details` in `network` (`watch` / `stop` / `get_profile`): Includes full request & response headers, cookies, and bodies (default: `false`).
  - `includeRawResponse` in `memory` and `network`: Hides raw JSON payloads when false (default: `false`).
  - `includeExtensions` in `get_app_info`: Hides the full service extensions list when false (default: `false`).
  - `includeRawNode` in `widget` (action: `inspect`): Hides raw JSON layout nodes when false (default: `false`).

- **State Options**:
  - `forceGC` in `memory` (action: `get_snapshot` / `save` / `diff_allocations`): Runs garbage collection before inspection (default: `true`/`false`).

---

## Troubleshooting

### Connection Fails
- Ensure your Flutter application is running in debug or profile mode. Release builds disable the VM Service.
- Check that the port is accessible. If running on physical devices or emulators, you may need to map ports using ADB: `adb reverse tcp:8181 tcp:8181`.
- If `discover_apps` fails to connect, verify that your application has initialized the Dart Development Service (DDS). You can check by running `discover_apps` with `autoConnect: false` to list active endpoints.
 
### Layout File Path Mapping Fails
- When connecting via `connect`, ensure you provide the absolute path to your local Flutter project directory in the `workspace_root` argument. This allows the path resolver to match package references back to your local files.

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
