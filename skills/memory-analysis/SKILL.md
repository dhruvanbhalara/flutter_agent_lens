---
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
