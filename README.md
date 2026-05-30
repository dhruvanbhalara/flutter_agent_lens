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
| `connect_to_app` / `connect` | `uri` (required, or `vmServiceUri` for alias), `workspace_root` (optional) | Connect to a running Flutter application via its VM Service URI. |
| `list_running_apps` | None | Scan for running Flutter VM Service ports on the host. |
| `autodiscover_app` / `discover_apps` | `workspace_root` (optional) | Scan active OS processes and connect automatically if exactly one application is running. |
| `disconnect` | None | Disconnect from the currently active application. |
| `get_app_info` | None | Retrieve VM metadata, isolates, platform details, and active extension RPCs. |

### Performance and Build

| Tool Name | Parameters | Description |
| :--- | :--- | :--- |
| `diagnose_jank` | `duration_seconds` (default: 3) | Analyze frame render times and highlight frames exceeding the 16.6ms budget. |
| `get_cpu_profile` | `duration_seconds` (default: 3) | Sample CPU ticks to identify performance hotspots in Dart functions. |
| `get_widget_rebuild_counts` | `duration_seconds` (default: 3) | Track widget rebuild counts to identify unnecessary layout updates. |
| `hot_reload` | None | Trigger a hot reload on the connected main isolate. |
| `analyze_bundle_size` | `build_target` (default: 'apk') | Parse local `code-size-details.json` maps to find bloated packages. |

### Layout Inspection

| Tool Name | Parameters | Description |
| :--- | :--- | :--- |
| `inspect_layout_constraints` / `inspect_widget` | `widget_id` (required, or `widgetId` for alias) | Inspect parent constraints, render size, and diagnostics of a widget. |
| `toggle_widget_selection` | `enabled` (required) | Toggle the on-device widget selection overlay. |
| `toggle_package_widgets` | `enabled` (required) | Configure whether third-party packages appear in the inspector tree. |
| `toggle_layout_guidelines` / `toggle_debug_paint` | `enabled` (required) | Toggle layout guidelines (debug paint) on the device. |
| `toggle_oversized_images` | `enabled` (required) | Highlight oversized images by inverting their colors. |
| `toggle_repaint_rainbow` | `enabled` (required) | Show color borders around repaint boundaries during redraws. |
| `toggle_baselines` | `enabled` (required) | Render alignment baselines for text rendering. |
| `toggle_slow_animations` | `enabled` (required) | Apply a 5x time dilation factor to slow down UI animations. |
| `toggle_debug_flag` | `flag_name` (required), `value` (required) | Set a custom value for any registered Flutter service extension flag. |

### Memory and Debugging

| Tool Name | Parameters | Description |
| :--- | :--- | :--- |
| `audit_class_memory_leak` | `class_name` (required) | Scan heap instances of a class to verify if disposed objects are leaking. |
| `diff_heap_allocations` | `duration_seconds` (default: 3), `expression` (optional), `force_gc` (default: true) | Calculate memory growth and instance delta metrics over a window. |
| `get_object_referrers` | `object_id` (required), `limit` (default: 15) | Trace reference paths keeping an object alive in the heap. |
| `get_call_stack` | `limit` (default: 20) | Retrieve stack frames of active or paused isolates. |
| `set_exception_pause_mode` | `mode` (required: 'None', 'Unhandled', 'All') | Configure exception pausing behavior. |
| `add_breakpoint` | `file_path` (required), `line` (required), `column` (optional) | Install a breakpoint in a source file. |
| `remove_breakpoint` | `breakpoint_id` (required) | Remove a breakpoint. |
| `eval_expression` / `evaluate_expression` | `expression` (required) | Evaluate a Dart expression in the context of the running application library. |

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
- If `autodiscover_app` fails to connect, verify that your application has initialized the Dart Development Service (DDS). You can check by running `list_running_apps` to list active endpoints.

### Layout File Path Mapping Fails
- When connecting via `connect_to_app`, ensure you provide the absolute path to your local Flutter project directory in the `workspace_root` argument. This allows the path resolver to match package references back to your local files.

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
