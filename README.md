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

All tools require an active connection to a running application, unless stated otherwise. MCP clients discover tool schemas and parameters automatically from the server.

| Category | Tool | Description |
| :--- | :--- | :--- |
| **App Connection** | `connect`<br>`disconnect`<br>`discover_apps`<br>`get_app_info` | Establish connection, discover running apps, and query VM metadata. |
| **DTD Integration** | `connect_dtd`<br>`get_active_location` | Interoperate with Dart Tooling Daemon (DTD) for active file path queries. |
| **Diagnostics** | `diagnose_jank`<br>`get_cpu_profile`<br>`get_widget_rebuild_counts`<br>`start_profiling` / `stop_profiling`<br>`start_tracking_rebuilds` / `stop_tracking_rebuilds` | Track render times, CPU execution hotspots, and widget rebuild cycles. |
| **Widget Inspector** | `get_widget_tree`<br>`inspect_widget`<br>`toggle_widget_selection`<br>`toggle_package_widgets`<br>`toggle_debug_flag` | Traverse widget trees and inspect constraints or toggle debug overlays. |
| **Memory Analysis** | `get_memory_snapshot`<br>`save_snapshot`<br>`list_snapshots`<br>`compare_snapshots`<br>`diff_heap_allocations`<br>`audit_class_memory_leak`<br>`get_object_referrers` | Monitor class allocations, diff snapshots, and inspect leak retaining paths. |
| **Logs & Network** | `fetch_console_logs`<br>`get_network_profile`<br>`start_network_capture` / `stop_network_capture`<br>`trigger_scroll_gesture` | Stream logs, capture HTTP network payloads, and simulate device scrolls. |
| **Screenshots** | `take_screenshot`<br>`compare_layout_screenshots` | Capture app screens and perform visual pixel-diff regression tests. |
| **Platform / Code** | `analyze_bundle_size`<br>`validate_deep_links` | Run local bundle size checks and check deep-link configurations. |
| **Hot Reload** | `hot_reload`<br>`hot_restart` | Refresh code changes and reset app state (routes via DTD if active). |
| **Debugger** | `get_call_stack`<br>`set_exception_pause_mode`<br>`add_breakpoint`<br>`remove_breakpoint`<br>`evaluate_expression` | Control breakpoints, fetch stack frames, and evaluate Dart expressions. |

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
