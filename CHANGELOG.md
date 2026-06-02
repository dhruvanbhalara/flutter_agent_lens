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
