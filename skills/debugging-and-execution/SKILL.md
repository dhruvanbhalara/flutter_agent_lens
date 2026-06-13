---
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
