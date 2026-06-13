---
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
