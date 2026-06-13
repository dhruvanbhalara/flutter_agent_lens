---
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
