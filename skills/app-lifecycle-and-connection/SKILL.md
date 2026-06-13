---
name: app-lifecycle-and-connection
description: "Discover running Flutter applications, connect/disconnect using VM Service URIs, trigger hot reloads or hot restarts, and inspect application environment information."
---

# App Lifecycle and Connection Management

Use this skill when you need to connect to a target Flutter application, inspect its active VM/isolates, retrieve app environment info, or trigger code reloading/restarts.

## Exposed Tools
*   `discover_apps`: Scans local ports and discovers running Flutter/Dart instances.
*   `connect`: Attaches the MCP server to a target VM Service URI.
*   `disconnect`: Detaches from the currently connected VM Service.
*   `get_app_info`: Fetches VM versions, active isolates, and available extension services.
*   `hot_reload`: Triggers a state-preserving hot reload of modified source files.
*   `hot_restart`: Triggers a full hot restart of the application state.

## Guidelines & Workflows

### 1. Connecting to a Flutter App
*   Always attempt to find running instances automatically first using `discover_apps`. Pass `workspace_root` to resolve source file paths.
*   If automatic discovery fails, ask the user to provide the VM Service URI (displayed in their `flutter run` terminal console).
*   Call `connect` with the `uri` (e.g. `http://127.0.0.1:8181/auth_token=/`) and `workspace_root` to establish connection.

### 2. Inspecting Connected Apps
*   After connecting, call `get_app_info` to verify:
    - Target Dart SDK version.
    - Active isolate IDs.
    - Registered Flutter service extensions (like `ext.flutter.inspector` or `ext.flutter.debugPaint`).

### 3. Reloading and Restarting
*   After making code edits (e.g. fixing layout or tweaking values), use `hot_reload` to push changes without losing application state.
*   If you modified core structure (e.g., added assets, changed initialization logic, or modified application routing), use `hot_restart` to perform a full reset.
*   *Note: Standard compilation errors will be reported in stderr if the reload fails.*
