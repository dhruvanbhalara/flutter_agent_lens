// Generated file. Do not edit manually.

const Map<String, String> mcpSkillsData = {
  'widget_inspection_and_layout': '''---
name: widget-inspection-and-layout
description: "Inspect widget tree hierarchy, view widget properties, toggle widget selection mode on-device, capture screenshots, and systematically diagnose layout constraint violations."
---

# Widget Inspection and Layout Verification

Use this skill when you need to inspect the UI layout hierarchy, view widget properties, capture screenshots, verify visual changes, or resolve Flutter layout exceptions (like RenderFlex overflow, unbounded height/width, or ParentData misuse).

## Exposed Tools
*   `get_widget_tree`: Fetches the current widget tree of the running Flutter application.
*   `inspect_widget`: Retrieves detailed properties and layout constraints of a widget by its ID.
*   `toggle_widget_selection`: Enables or disables on-device widget selection (Widget Inspector overlay) mode.
*   `take_screenshot`: Captures a standalone screenshot (PNG) of the running app.
*   `compare_layout_screenshots`: Captures or compares screenshots to execute pixel diff checks.

---

## The Flutter Constraint Model
Flutter layout operates on a strict negotiation rule:
> **Constraints go down. Sizes go up. Parent sets position.**

1. A parent widget passes **constraints** (min/max width and height) to its child.
2. The child determines its own **size** within those constraints.
3. The parent decides the child's **position**.

Layout errors occur when this negotiation fails — typically when a parent provides **unbounded** constraints (infinite width or height) and the child attempts to expand infinitely.

---

## Error Signature Catalog & Diagnostics

| Error Message | Root Cause | Quick Fix |
|---|---|---|
| `Vertical viewport was given unbounded height` | Scrollable (`ListView`, `GridView`) inside unconstrained vertical parent (`Column`) | Wrap in `Expanded` or `SizedBox(height: ...)` |
| `An InputDecorator...cannot have an unbounded width` | `TextField` inside unconstrained horizontal parent (`Row`) | Wrap in `Expanded` |
| `A RenderFlex overflowed by X pixels` | Child exceeds parent's allocated constraints | Wrap in `Expanded`, `Flexible`, or use `overflow: TextOverflow.ellipsis` |
| `Incorrect use of ParentData widget` | `Expanded` outside `Flex`, `Positioned` outside `Stack` | Move widget to be direct child of correct parent |
| `RenderBox was not laid out` | **Cascading error** — look upstream in stack trace | Fix the primary constraint error above it |

*Rule*: Always fix the **first** error in the stack trace. `RenderBox was not laid out` is almost always a cascading side effect of an upstream constraint failure.

---

## Layout Resolution Decision Flow

- If error contains "unbounded height":
  - Wrap scrollable child in Expanded or SizedBox
- If error contains "unbounded width":
  - Wrap TextField/InputDecorator in Expanded
- If error contains "RenderFlex overflowed":
  - If text overflow: Add overflow: TextOverflow.ellipsis + Expanded wrapper
  - If widget overflow: Wrap in Expanded or Flexible
- If error contains "ParentData":
  - Ensure Expanded is direct child of Row, Column, or Flex
  - Ensure Positioned is direct child of Stack
- If error contains "RenderBox was not laid out":
  - Ignore this error and fix the primary layout exception listed above it

---

## Layout Controls Comparison

| Widget | Behavior | Use When |
|---|---|---|
| `Expanded` | Forces child to fill ALL remaining space in a Flex container. | Child should stretch to fill available space. |
| `Flexible` | Allows child to be SMALLER than remaining space, but limits it. | Child has a natural size but should shrink rather than overflow. |
| `SizedBox` | Provides absolute fixed constraints. | You know the exact width or height dimensions needed. |
| `ConstrainedBox` | Sets min/max constraints on dimensions. | You need bounded flexibility (e.g., minWidth/maxWidth). |

---

## Coding Examples & Fix Patterns

### 1. Fixing Unbounded Height (ListView in Column)
*Before (throws `Vertical viewport was given unbounded height`):*
```dart
Column(
  children: <Widget>[
    const Text('Header'),
    ListView(
      children: const <Widget>[
        ListTile(title: Text('Item 1')),
        ListTile(title: Text('Item 2')),
      ],
    ),
  ],
)
```
*After (resolved):*
```dart
Column(
  children: <Widget>[
    const Text('Header'),
    Expanded(
      child: ListView(
        children: const <Widget>[
          ListTile(title: Text('Item 1')),
          ListTile(title: Text('Item 2')),
        ],
      ),
    ),
  ],
)
```

### 2. Fixing Unbounded Width (TextField in Row)
*Before (throws `An InputDecorator...cannot have an unbounded width`):*
```dart
Row(
  children: [
    const Icon(Icons.search),
    TextField(),
  ],
)
```
*After (resolved):*
```dart
Row(
  children: [
    const Icon(Icons.search),
    Expanded(
      child: TextField(),
    ),
  ],
)
```

### 3. Fixing RenderFlex Overflow (Text in Row)
*Before (throws `A RenderFlex overflowed by X pixels on the right`):*
```dart
Row(
  children: [
    const Icon(Icons.info),
    Text('This is a very long text that will overflow the screen width'),
  ],
)
```
*After (resolved):*
```dart
Row(
  children: [
    const Icon(Icons.info),
    Expanded(
      child: Text(
        'This is a very long text that will overflow the screen width',
        overflow: TextOverflow.ellipsis,
      ),
    ),
  ],
)
```

### 4. Fixing ParentData Misuse
*Before (throws `Incorrect use of ParentData widget`):*
```dart
// Expanded must be a DIRECT child of Row/Column/Flex
Container(
  child: Expanded(  // WRONG: Expanded is inside Container, not directly inside Flex
    child: Text('Hello'),
  ),
)
```
*After (resolved):*
```dart
Row(
  children: [
    Expanded(  // OK: Direct child of Row (a Flex widget)
      child: Text('Hello'),
    ),
  ],
)
```

---

## Guidelines & Workflows

### 1. Navigating the Widget Tree
*   Always start with `get_widget_tree` when looking for specific layout elements.
*   Pass `projectOnly: true` (recommended) to filter out framework and package widgets.
*   Adjust `maxDepth` if the tree is too large or too shallow (defaults to 15).

### 2. Inspecting Layout and Constraints
*   Identify the target widget's ID from the output of `get_widget_tree`.
*   Call `inspect_widget` with the `widgetId` to inspect:
    - RenderObject properties (size, constraints, paint bounds).
    - Flex constraints (crossAxisAlignment, mainAxisAlignment).
    - File location/source line of the widget definition.

### 3. On-Device Selection
*   If you need the user to choose a widget on their screen, call `toggle_widget_selection` with `enabled: true`. This activates the Flutter Inspector overlay.

### 4. Layout Verification & Visual Diffs
*   To establish a baseline before making a layout modification, run `compare_layout_screenshots` with `action: "capture_baseline"` and a unique `baseline_name` (e.g., `login_page`).
*   To verify a UI reload or hot restart:
    - Run the tool with `action: "compare"` using the same `baseline_name`.
    - Adjust the `threshold` (e.g., `0.98`) to allow slight rendering discrepancies.
    - If differences exceed the threshold, refer to the generated diff image at `build/mcp_screenshots/{baseline_name}_diff.png` to inspect the highlighted differences.
''',
  'app_lifecycle_and_connection': '''---
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
''',
  'network_and_deep_links': '''---
name: network-and-deep-links
description: "Start/stop network traffic captures, analyze HTTP request profiles, and validate Android/iOS deep link configurations."
---

# Network Profiling and Deep Link Validation

Use this skill when you need to inspect HTTP requests/responses, analyze network performance, or validate app deep linking configurations on Android and iOS.

## Exposed Tools
*   `get_network_profile`: Retrieves current network profile request histories.
*   `start_network_capture`: Begins a stateful capture session for HTTP network traffic.
*   `stop_network_capture`: Ends the capture session and retrieves request histories.
*   `validate_deep_links`: Validates scheme/host configurations on Android and iOS.

## Guidelines & Workflows

### 1. Network Capture and Profiling
*   To trace network requests triggered by a specific action (e.g. login submission):
    - Run `start_network_capture` to begin capturing traffic.
    - Ask the user to execute the flow.
    - Run `stop_network_capture` to get the list of requests.
*   Sort or filter the requests (using `sortBy: "time"`, `sortBy: "duration"`, or `sortBy: "size"`).
*   Look for failed requests (non-2xx status codes), high latency, or large payloads. Pass `includeRawResponse: true` if you need to read the full payload body.

### 2. Validating Deep Links
*   If deep links are not launching the app or navigating to the correct screen:
    - Call `validate_deep_links` with `platform: "android"` or `platform: "ios"`.
    - Provide the build configuration / build variant parameters if targetting custom schemes.
    - Review the generated validation report to identify errors in `AndroidManifest.xml` (Android App Links) or `Runner.entitlements` (iOS Universal Links).
''',
  'bundle_analysis': '''---
name: bundle-analysis
description: "Analyze Flutter build size metadata to identify high footprint components and optimize application bundle sizes."
---

# Bundle Size Analysis

Use this skill when you need to inspect compiled output binaries, identify which libraries/assets are consuming the most space, or optimize the final application footprint.

## Exposed Tools
*   `analyze_bundle_size`: Analyzes size mapping files from the `build/` directory.

## Guidelines & Workflows

### 1. Analyzing Build Sizes
*   Before running this tool, ensure that a Flutter build has been run with the `--analyze-size` flag (e.g. `flutter build apk --analyze-size`). This generates a `.json` size mapping file in the build directory.
*   Call `analyze_bundle_size` with the target `build_target` (e.g. `apk`, `appbundle`, `ios`, or `web`) and optional `target_platform`.
*   Inspect the output report:
    - Focus on the largest dependency libraries (e.g., `package:flutter`, external packages).
    - Find large assets (fonts, images, audio files) that could be compressed or deferred.
    - Check the overhead of the compiled Dart engine vs user source code.
''',
  'memory_analysis': '''---
name: memory-analysis
description: "Audit class memory leaks, perform heap allocation diffs, capture/compare heap snapshots, and trace object retaining paths in the VM garbage collection graph."
---

# Memory Analysis and Leak Auditing

Use this skill when you need to inspect class allocations, diagnose memory growth, find retained objects causing leaks, or analyze heap footprint changes over time.

## Exposed Tools
*   `get_memory_snapshot`: Fetches a general snapshot overview of application and framework class allocations.
*   `audit_class_memory_leak`: Verifies if instances of a specific class are leaking (not garbage-collected).
*   `diff_heap_allocations`: Calculates class allocation size and count deltas over a sampling window.
*   `save_snapshot`: Captures and stores a named memory snapshot.
*   `list_snapshots`: Lists all captured memory snapshots.
*   `compare_snapshots`: Compares two named memory snapshots to analyze allocation deltas.
*   `get_object_referrers`: Retrieves the retaining path (referrers) keeping an object alive in the heap.

---

## Memory Lifecycle & Management Best Practices

### 1. Resource Lifecycle & Explicit Disposal
*   **Explicit Disposal**: Always close `StreamController`, `Timer`, `FocusNode`, `AnimationController`, and `ChangeNotifier`/`ScrollController` in the class `dispose()` method.
*   **Late Initialization**: Use `late` to delay object creation until it's actually needed, reducing initial memory footprint.

### 2. Garbage Collection (GC) Pressure
*   **Generational GC**: Dart's GC is optimized for short-lived objects. However, creating thousands of objects in a single frame causes jank.
*   **Object Re-use**: Avoid creating new objects in `build()` or high-frequency loops. Reuse data structures where possible.
*   **WeakReference**: Use `WeakReference` for caches that should not prevent garbage collection.

### 3. Large Asset & Data Handling
*   **Image Caching**: Verify that large images use `cacheWidth` and `cacheHeight` in `Image.network` or `Image.asset` to avoid loading high-resolution images into memory at full size.
*   **Pagination**: Never load entire datasets into memory. Use server-side or local database pagination (Isar, SQLite).
*   **Streaming**: For large files or real-time data, use `Stream` to process data in chunks rather than buffering the entire content in memory.

---

## Guidelines & Workflows

### 1. General Heap Overview
*   Call `get_memory_snapshot` with `forceGC: true` to get a clean baseline of current memory allocations. Look for classes with unusually high instance counts or memory sizes.

### 2. Auditing Class Leaks
*   If a specific widget, controller, or service (e.g. `_MyHomePageState`) is suspected of leaking after pop/dismiss actions:
    - Instruct the user to perform the action (e.g., open and close the screen).
    - Call `audit_class_memory_leak` passing the `class_name`.
    - If instances remain in memory, the tool will return their VM IDs.

### 3. Finding Leaking Retaining Paths
*   When a class leak is detected, use the instance IDs returned by `audit_class_memory_leak`.
*   Call `get_object_referrers` with the target `object_id` to inspect the retaining path.
*   Identify which parent objects, global variables, event streams, or closures are holding references to the leaked instance, and suggest fixes (e.g., closing stream subscriptions, disposing controllers, nullifying variables).

### 4. Heap Comparison Workflows
*   To test a specific action's memory impact:
    - Save a baseline snapshot: `save_snapshot(name: "before_flow")`.
    - Execute the user flow/action.
    - Save a post-flow snapshot: `save_snapshot(name: "after_flow")`.
    - Run `compare_snapshots(before: "before_flow", after: "after_flow")` to pinpoint which class instance counts increased.
''',
  'debugging_and_execution': '''---
name: debugging-and-execution
description: "Manage breakpoints, retrieve call stack frames, fetch console/developer logs, evaluate Dart expressions, toggle debug flags, configure exception pause modes, and systematically diagnose type soundness/null safety issues."
---

# Debugging, Expression Execution, and Soundness

Use this skill when you need to inspect console output, pause execution, set breakpoints, evaluate live Dart expressions, inspect execution stacks, or systematically resolve Dart type safety and null safety issues.

## Exposed Tools
*   `fetch_console_logs`: Retrieves recent standard output, error, and logging streams.
*   `add_breakpoint`: Adds a VM breakpoint at a specific source file line.
*   `remove_breakpoint`: Removes an active breakpoint by ID.
*   `get_call_stack`: Retrieves current execution stack frames of running/paused isolates.
*   `evaluate_expression`: Evaluates a Dart expression in the context of the running app.
*   `toggle_debug_flag`: Toggles Flutter framework debug options (e.g. Paint bounds, repaint rainbow).
*   `set_exception_pause_mode`: Configures whether the debugger pauses on all exceptions, unhandled exceptions, or none.

---

## Centralized Logging Guidelines
To ensure clean production logs and debug capability:
- **Centralized Logger**: Use a centralized `AppLogger` class for logging. NEVER use `print()` or raw `debugPrint()` in production code.
- **Log Levels**: Define levels: `verbose`, `debug`, `info`, `warning`, `error`, `fatal`.
  - *Development*: Log everything (verbose and above).
  - *Staging*: Log info and above.
  - *Production*: Log warning and above only, routing errors/fatals to Crashlytics.
- **Contextual Logs**: Include error and stack trace context: `AppLogger.error('Failed to fetch user', error: e, stackTrace: st)`.
- **PII Guard**: Never log sensitive user data (passwords, auth tokens, personal identifiers).

---

## Type Safety & Soundness
Enforce Dart's sound type system to prevent runtime crashes and compile-time issues:
*   **Avoid dynamic**: Explicitly use typed variables or `Object?`. Statically typed code allows better AOT compiler optimizations.
*   **Method Overrides**: Maintain sound return types (covariant) and parameter types (contravariant). Never tighten a parameter type in a subclass unless explicitly marked with `covariant`.
*   **Generics & Collections**: Explicitly type generic collections (e.g., `List<int>` instead of `List<dynamic>`). Never assign `List<dynamic>` directly to typed collections.
*   **Downcasting**: Avoid implicit downcasts from `dynamic`. Use explicit casts (`as Type`) only when the runtime type is guaranteed, otherwise type check first (`if (x is Type)`).
*   **Strict Casts**: Add the following configuration to `analysis_options.yaml` to enforce strict type checking:
    ```yaml
    analyzer:
      language:
        strict-casts: true
    ```

---

## Null Safety Error Patterns

| Error Signature | Cause | Resolution Pattern |
|---|---|---|
| `Property cannot be accessed on nullable receiver` | Attempted member access on a nullable object (`Type?`). | Use null-safe member access `?.` or pattern-match using `if (obj case final o?)`. |
| `Non-nullable instance field must be initialized` | A non-nullable class property was declared without an initializer. | Initialize inline, use `late` (only if guaranteed to initialize before use), or mark the type nullable `?`. |
| `The argument type can't be assigned` | A nullable expression (`Type?`) is passed to a parameter expecting a non-nullable `Type`. | Perform a local null-check, provide a default fallback via `??`, or use the null assertion operator `!` (only when absolutely guaranteed). |

*Rule*: Avoid the null assertion operator `!` wherever possible — prefer pattern matching, early returns, or conditional guard clauses. Use the `_` wildcard for unused variables.

---

## Runtime Error & Exception Handling
- **Exceptions**: Catch `Exception` subtypes (e.g., `FormatException`, `SocketException`) for recoverable runtime failures.
- **Errors**: Never catch `Error` or its subtypes (e.g., `TypeError`, `ArgumentError`). Errors represent programming bugs that must be resolved in source code rather than handled at runtime.
- **Rethrowing**: Use the `rethrow` keyword inside a catch block to propagate exceptions while fully preserving the original stack trace.

---

## Workflow: Diagnosing & Resolving Issues

### 1. Automated Resolution Loop
When fixing compilation/static errors, follow this workflow:
- [ ] **Step 1**: Identify issues by running static analysis:
  ```bash
  dart analyze . --fatal-infos
  ```
- [ ] **Step 2**: Preview automated fixes:
  ```bash
  dart fix --dry-run
  ```
- [ ] **Step 3**: Apply automated fixes:
  ```bash
  dart fix --apply
  ```
- [ ] **Step 4**: Verify resolution by running analysis and unit tests:
  ```bash
  dart analyze . && dart test
  ```
- [ ] **Step 5**: If new runtime `TypeError` exceptions appear after fixing, verify that you didn't introduce an invalid `as T` downcast or read an uninitialized `late` variable.

### 2. Reading Application Logs
- Call `fetch_console_logs` to view standard prints, logs, or caught framework exceptions.
- Increase the `limit` parameter to retrieve deeper log histories.

### 3. Managing Breakpoints and Call Stacks
- Use `add_breakpoint` passing the target absolute `file_path` and `line` number.
- When the execution pauses on a breakpoint, run `get_call_stack` to inspect the active frame stack and trace execution parameters.
- Call `remove_breakpoint` when done.

### 4. Evaluating Expressions
- Use `evaluate_expression` to inspect runtime variables, call methods, or query state live.
- When paused at a breakpoint, supply the `frame_index` to evaluate the expression directly within that stack frame's local scope.

### 5. Visual Debug Flags
- Use `toggle_debug_flag` to enable layout bounds visualization (`debugPaint`) or repaint outlines (`repaintRainbow`) to diagnose UI defects.
''',
  'performance_and_rebuilds': '''---
name: performance-and-rebuilds
description: "Diagnose rendering jank, trace CPU execution profiles, track widget rebuild counts, and run stateful performance profiling sessions."
---

# Performance Profiling & Rebuild Optimization

Use this skill when you need to analyze application responsiveness, diagnose UI frame lag (jank), identify CPU bottlenecks, or minimize unnecessary widget rebuilds.

## Exposed Tools
*   `diagnose_jank`: Collects frame time metrics to identify rendering delays.
*   `get_cpu_profile`: Samples CPU usage to find function execution hotspots.
*   `get_widget_rebuild_counts`: Finds frequently rebuilding widgets over a sampling window.
*   `start_tracking_rebuilds`: Starts a stateful rebuild tracking session.
*   `stop_tracking_rebuilds`: Ends the rebuild tracking session and retrieves the aggregated report.
*   `start_profiling`: Starts a stateful CPU and frame profiling session.
*   `stop_profiling`: Ends the profiling session and returns the jank/CPU analysis.

---

## Profiling & Target Metrics
When optimizing and diagnosing performance, aim for these standard metrics:
*   **Frame Build Time**: < 16ms per frame (60fps) or < 8.33ms (120fps) to avoid jank.
*   **Screen Transition latency**: < 100ms.
*   **Cold Start time**: < 2.0 seconds.

### Performance Rule: Always Profile in Profile Mode
Never rely on debug mode measurements for performance metrics. Debug mode includes additional verification overhead and has JIT compiler latency.
*   Always run the application in **profile mode**: `flutter run --profile`.
*   Monitor shader compilation jank on first run. If shader compilation causes jank, recommend compiling with SkSL warmup:
    ```bash
    flutter run --profile --cache-sksl --purge-persistent-cache
    ```

---

## Guidelines & Workflows

### 1. Diagnosing Frame lag (Jank)
*   If the user reports lag during interactions (e.g. scrolling list views, transition animations), run `diagnose_jank`.
*   Pass a short sampling duration (e.g., `duration_seconds: 5.0`).
*   Analyze the frame distribution (UI vs Raster thread times). Look for frames exceeding the frame budget.

### 2. Finding CPU bottlenecks
*   Use `get_cpu_profile` to collect CPU samples (typically over 3-5 seconds).
*   Analyze the call tree and top-sampled methods. Focus optimization efforts on high-percentage user code methods.

### 3. Resolving Excessive Rebuilds
*   rebuilds are a major source of UI jank. You can use two methods to track them:
    - **One-off window:** Call `get_widget_rebuild_counts` for a specified duration to watch widget rebuild frequencies.
    - **Stateful sessions:** Call `start_tracking_rebuilds` before performing a manual workflow, then call `stop_tracking_rebuilds` afterwards to retrieve the report.
*   Examine the rebuild counts. Pay close attention to widgets rebuild counts that match the number of frames rendered—this indicates they are rebuilding on every single frame.
*   Suggest optimizations like using `const` constructors, extracting stateful subtrees, or optimizing state providers.
''',
};
