## Unreleased

### Fixed
- Fixed target application memory leak by automatically disposing DevTools `WidgetInspectorService` object groups (`disposeGroup`) on all execution paths (including early returns and errors).

### Refactored
- Unified telemetry sampling architecture by allowing `safeSamplingWindow` to accept nullable `VmService?` and introduced `SamplingResultX.writeWarningIfInterrupted` for centralized output warning formatting.
- Enhanced `VmServiceX` extension with `safeToggleFlutterExtension` to handle RPC errors gracefully during setup/teardown.

### Performance
- Added chunked worker batching (`_batchAsync`) for parallel `getRetainingPath` RPC calls in `memory audit_leak` to protect target isolate from CPU/GC pressure.
- Added LRU capacity eviction and snapshot limit overrides (`limit` parameter) for server-side memory snapshot storage.

### Testing
- Added unit tests covering DevTools inspector object group disposal, safe extension toggling, null VmService sampling, and memory snapshot capacity limits.

## 1.8.0

### Added
- Added `safeSamplingWindow` utility for crash-aware duration sampling that monitors VM Service `onDone` event.
- Added graceful crash recovery and partial data flushing across Category A (snapshot-bracket) and Category B (incremental buffer) tools (`console_logs watch`, `network watch`, `rebuild_tracking`, `memory get_memory_timeline`, `memory watch_gc_pressure`, `diagnose_jank`, `get_cpu_profile`, `diff_heap_allocations`).
- Added GitHub alert warning headers (`> [!WARNING]`) in tool outputs when sampling is interrupted by application crash or disconnect.

### Refactored
- Standardized tool schema parameter property names to camelCase (`durationSeconds`, `forceGC`, `includeDetails`, `slowThresholdMs`, `flagName`, `frameIndex`, `excludeFlutterWidgets`).
- Added `intArg` and `doubleArg` helpers to `CallToolRequestX` extension to eliminate verbose numeric casting across mixin tool handlers.
- Introduced `VmServiceX` extension with `toggleFlutterExtension` and `evalSafe` for standardized DevTools extension toggles and safe evaluation with sentinel handling.

## 1.7.0

### Added
- Refactored `fetch_console_logs` into `console_logs` composite tool supporting `fetch` and live `watch` stream actions with filter support.
- Added `watch` action to `network` composite tool for streaming live HTTP traffic over a duration window with `slow_threshold_ms` detection.
- Added `include_details` parameter (default: `false`) to `network` tool actions (`watch`, `get_profile`, `stop`) to fetch full HTTP headers, cookies, and payload bodies.
- Added `get_request_details` action to `network` composite tool for detailed inspection of HTTP request/response headers, cookies, timing, and decoded body payloads.
- Added 6 new memory tool actions (`force_gc`, `start_gc_stream`, `stop_gc_stream`, `get_memory_timeline`, `watch_gc_pressure`, `explain_memory_breakdown`) to `memory` composite tool.


## 1.6.2


### Added
- Added `get_navigation_stack` MCP tool to inspect active routes, current URL, and nested navigator trees via the Dart VM Service.

## 1.6.1

### Added
- Added `exclude_flutter_widgets` option (default: `true`) to `rebuild_tracking` to filter out built-in framework and dependency widgets.

## 1.6.0

### Changed
- Grouped 41 granular tools into 21 action-based composite tools to reduce context token usage.
- Enabled dynamic tool registration, showing debugging tools only after establishing a connection.
- Replaced individual format parameters with a server-wide response format configuration.

### Added
- Added response limit and list size configurations (`limit` and `topN`) for memory, profiling, and network logs.
- Added tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`) to tool schemas.

## 1.5.5

- Replaced flaky HTTP capture stream listeners with VM Service snapshot diffing, resolving silent failures and returning 0 requests on Android/AOT runtimes.
- Added platform compatibility safety checks and fallback parsing logic for differing VM Service versions.

## 1.5.4

- Resolved memory leaks and background process accumulation when disconnecting from debug sessions.
- Lowered memory consumption during long debugging sessions by adding caps to path-resolution caches.
- Standardized tool arguments and connection schemas for more reliable tool actions (like screenshots, breakpoints, and widget trees).
- Improved port and process scanning reliability on Windows, Mac, and Linux environments.

## 1.5.3

- Filtered out system isolates when connecting to the VM service to avoid selecting non-user code.
- Implemented automatic recovery and retry logic when encountering sentinel or collected isolate ID errors.

## 1.5.2

- Deprecated and removed the redundant `dual` format option across all tools to optimize token usage.

## 1.5.1

- Split the monolithic server file into 12 separate class mixins for better maintainability.
- Consolidated the tool list in the README file.

## 1.5.0

- Subscribed to `onServiceEvent` before calling `streamListen(EventStreams.kService)` in `connection_handlers.dart` to resolve a VM service discovery race condition.
- Routed `handleHotReload` and `handleHotRestart` through DTD service calls if DTD is active, VM service callbacks (`s1.reloadSources` with `isolateId` and `s1.hotRestart`) if available, or isolate-level extensions as a fallback.
- Added dependency on `dtd` package to support direct Dart Tooling Daemon communication.

## 1.4.1

- Refactored and optimized internal MCP tool handlers for widget tracking, memory diffing, and network capturing.
- Parameterized location map parsers (`_parseLocationsMap` and `_parseNewLocationsMap`) to remove local duplicates and share code across rebuild tracking handlers.
- Standardized class allocation diff tables and sorted delta logic into shared helpers in `memory_handlers.dart`.
- Converted local size formatting (`formatSize`) in `network_handlers.dart` and `memory_handlers.dart` to a library-wide unified `_formatBytes` helper on `FlutterAgentLensServer`.
- Consolidated rebuild tracking availability checks under `_isTrackRebuildSupported()`.

## 1.4.0

- Added a `format` parameter (`markdown`, `json`, `dual`) to verbose tools so clients can drop JSON and base64 payloads when they're not needed.
- `get_cpu_profile` now filters out functions with 0 ticks before returning results, cutting payload size by ~99% on typical profiles.
- Added `includeRawNode` to `inspect_widget` and `includeRawResponse` to `get_object_referrers` and `stop_network_capture`. Both default to false, skipping large raw VM payloads unless requested.
- `diff_heap_allocations` now returns only the top 50 classes with allocation changes instead of the full list.
- `stop_tracking_rebuilds` and `get_widget_rebuild_counts` cap rebuild lists to the top N active widgets.
- Added `includeExtensions` to `get_app_info` (defaults to false). Omits the 60+ registered Flutter service extensions, saving ~3-4 KB per call.
- Removed decorative separators (`===`, `---`), markdown headings (`###`, `**bold**`), backtick wrapping, and column-alignment padding (`.padLeft()`, `.padRight()`) from all tool response output paths. Plain text labels replace them throughout.
- Migrated `compare_snapshots` to the `_serializeDualFormat` path, adding `format` parameter support and structured JSON output.
- All tool response sizes reduced by 15-40% with no semantic information removed.

## 1.3.0

- Added stateful tracking tools: `start_tracking_rebuilds` / `stop_tracking_rebuilds`, `start_profiling` / `stop_profiling`, and `start_network_capture` / `stop_network_capture`.
- Added the `get_memory_snapshot` tool to list active class allocations.
- Added connection warnings when a Dart Tooling Daemon (DTD) URI is passed to `connect`.
- Fixed hot reload and hot restart hangs by dynamically checking service namespaces.
- Fixed isolate ID and library cache clearing after a hot restart.

## 1.2.0

- Added `take_screenshot` tool to capture native or Skia device screenshots, with automatic fallback to native captures when Impeller is active.
- Added `hot_restart` tool to trigger application state resets, with improved diagnostic messages when running without a host connection.
- Added `get_widget_tree` tool to recursively retrieve the active widget tree with local project widget filtering.
- Added memory snapshot tools (`save_snapshot`, `compare_snapshots`, `list_snapshots`) to cache and calculate class allocation differences.

## 1.1.0

- Added the `compare_layout_screenshots` tool to capture, verify, and highlight visual differences in layout screens.
- Added parameters to select the capture type (`device` or `skia`) and specify target devices.

## 1.0.0

- Initial version.
