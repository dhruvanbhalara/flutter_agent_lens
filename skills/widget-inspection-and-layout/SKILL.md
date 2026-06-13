---
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
