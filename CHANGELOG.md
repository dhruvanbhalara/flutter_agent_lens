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
