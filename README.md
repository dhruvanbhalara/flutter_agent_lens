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

## Requirements

- Dart SDK / Flutter SDK (installed and added to the system PATH).
- A Flutter application running in debug or profile mode.

---

## Setup

### 1. Install the CLI

Activate the package globally to register the `flutter-agent-lens` binary:

```bash
dart pub global activate flutter_agent_lens
```

Ensure your global pub cache bin directory is in your system PATH (typically `~/.pub-cache/bin` on macOS/Linux or `%USERPROFILE%\AppData\Local\Pub\Cache\bin` on Windows).

### 2. Configure the MCP Host

Add the server details to the configuration file of your MCP client host:

#### Claude Desktop
Add the following to your configuration file (macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`, Windows: `%APPDATA%\Claude\claude_desktop_config.json`):

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
2. Click **+ Add New MCP Server**.
3. Set the configuration:
   - **Name**: `flutter_agent_lens`
   - **Type**: `command`
   - **Command**: `flutter-agent-lens`

---

## Tool Catalog

All tools require an active connection to a running application, unless stated otherwise.

### Connection and Discovery

| Tool Name | Parameters | Description |
| :--- | :--- | :--- |
| `connect` | `uri` or `vmServiceUri` (required), `workspace_root` (optional) | Connect to a running Flutter application via its VM Service URI. |
| `discover_apps` | `autoConnect` (optional, default: true), `workspace_root` (optional) | Automatically discover running Flutter applications on the host. |
| `disconnect` | None | Disconnect from the currently active application. |
| `get_app_info` | None | Retrieve VM metadata, isolates, platform details, and active extension RPCs. |

### Performance and Build

| Tool Name | Parameters | Description |
| :--- | :--- | :--- |
| `diagnose_jank` | `duration_seconds` (default: 3) | Analyze frame render times and highlight frames exceeding the 16.6ms budget. |
| `get_cpu_profile` | `duration_seconds` (default: 3) | Sample CPU ticks to identify performance hotspots in Dart functions. |
| `get_widget_rebuild_counts` | `duration_seconds` (default: 3) | Track widget rebuild counts to identify unnecessary layout updates. |
| `hot_reload` | None | Trigger a hot reload on the connected main isolate. |
| `hot_restart` | None | Trigger a hot restart of the running application. |
| `analyze_bundle_size` | `build_target` (default: 'apk') | Parse local `code-size-details.json` maps to find bloated packages. |

### Layout Inspection

| Tool Name | Parameters | Description |
| :--- | :--- | :--- |
| `get_widget_tree` | `maxDepth` (optional, default: 15), `projectOnly` (optional, default: false) | Retrieve the structured widget tree of the running Flutter application. |
| `inspect_widget` | `widgetId` (required) | Inspect parent constraints, render size, and diagnostics of a widget by its ID. |
| `compare_layout_screenshots` | `baseline_name` (required), `action` (required), `threshold` (optional) | Capture screenshots and run pixel diff comparison to detect visual changes. |
| `take_screenshot` | `screenshot_type` (optional), `device_id` (optional), `output_path` (optional) | Capture a standalone screenshot of the running Flutter application. |
| `toggle_widget_selection` | `enabled` (required) | Toggle the on-device widget selection overlay. |
| `toggle_package_widgets` | `enabled` (required) | Configure whether third-party packages appear in the inspector tree. |
| `toggle_debug_flag` | `flag_name` (required), `value` (required) | Configure Flutter framework debug flags (e.g. debugPaint, invertOversizedImages, repaintRainbow, debugPaintBaselinesEnabled, timeDilation). |

### Memory and Debugging

| Tool Name | Parameters | Description |
| :--- | :--- | :--- |
| `save_snapshot` | `name` (required), `forceGC` (optional, default: true) | Save a named memory allocation profile snapshot for later comparison. |
| `compare_snapshots` | `before` (required), `after` (required) | Compare two saved memory snapshots to calculate instance and byte differences. |
| `list_snapshots` | None | List saved memory snapshots available for comparison. |
| `audit_class_memory_leak` | `class_name` (required) | Scan heap instances of a class to verify if disposed objects are leaking. |
| `diff_heap_allocations` | `duration_seconds` (default: 3), `expression` (optional), `force_gc` (default: true) | Calculate memory growth and instance delta metrics over a window. |
| `get_object_referrers` | `object_id` (required), `limit` (default: 15) | Trace reference paths keeping an object alive in the heap. |
| `get_call_stack` | `limit` (default: 20) | Retrieve stack frames of active or paused isolates. |
| `set_exception_pause_mode` | `mode` (required: 'None', 'Unhandled', 'All') | Configure exception pausing behavior. |
| `add_breakpoint` | `file_path` (required), `line` (required), `column` (optional) | Install a breakpoint in a source file. |
| `remove_breakpoint` | `breakpoint_id` (required) | Remove a breakpoint. |
| `evaluate_expression` | `expression` (required) | Evaluate a Dart expression in the context of the running application library. |

### Logs and Gestures

| Tool Name | Parameters | Description |
| :--- | :--- | :--- |
| `fetch_console_logs` | `limit` (default: 50, max: 200) | Fetch buffered stdout, stderr, and logging streams. |
| `get_network_profile` | None | List HTTP requests recorded in the timeline. |
| `trigger_scroll_gesture` | `scroll_controller_expression` (required), `offset` (default: 500.0) | Programmatically animate a scroll controller for layout testing. |

---

## Troubleshooting

### Connection Fails
- Ensure your Flutter application is running in debug or profile mode. Release builds disable the VM Service.
- Check that the port is accessible. If running on physical devices or emulators, you may need to map ports using ADB:
  ```bash
  adb reverse tcp:8181 tcp:8181
  ```
- If `discover_apps` fails to connect, verify that your application has initialized the Dart Development Service (DDS). You can check by running `discover_apps` with `autoConnect: false` to list active endpoints.
 
 ### Layout File Path Mapping Fails
 - When connecting via `connect`, ensure you provide the absolute path to your local Flutter project directory in the `workspace_root` argument. This allows the path resolver to match package references back to your local files.

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
