part of '../../flutter_agent_lens.dart';

/// MCP tool handlers for debugging: call stack, breakpoints, and expression evaluation.
extension DebuggerHandlers on FlutterAgentLensServer {
  Future<CallToolResult> _handleGetCallStack(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 20;
    stderr.writeln('[mcp:get_call_stack] Fetching stack frames (limit=$limit)');

    try {
      final stack = await _vmService!.getStack(_isolateId!, limit: limit);
      final frames = stack.frames ?? [];
      final md = StringBuffer('### Call Stack Frames\n\n');

      if (frames.isEmpty) {
        md.writeln(
            'No call stack frames found. The isolate may not be paused.');
      } else {
        md.writeln('| Index | Function | Location |');
        md.writeln('| :--- | :--- | :--- |');
        for (var i = 0; i < frames.length; i++) {
          final f = frames[i];
          final funcName = f.function?.name ?? 'Unknown';
          final scriptUri = f.location?.script?.uri ?? 'Unknown';
          final line = f.location?.line?.toString() ?? '?';
          final resolvedPath = _pathResolver != null
              ? _pathResolver!.resolveToAbsolutePath(scriptUri)
              : scriptUri;
          md.writeln('| $i | `$funcName` | `$resolvedPath:$line` |');
        }
      }

      return _serializeDualFormat(
        title: '### Active Call Stack',
        markdownBody: md.toString(),
        structuredData: {
          'frames': frames
              .map((f) => {
                    'index': f.index,
                    'function': f.function?.name,
                    'script': f.location?.script?.uri,
                    'line': f.location?.line,
                    'column': f.location?.column,
                  })
              .toList(),
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:get_call_stack] ERROR: $e');
      stderr.writeln('[mcp:get_call_stack] STACKTRACE: $st');
      return CallToolResult(
          content: [TextContent(text: 'Failed to retrieve call stack: $e')],
          isError: true);
    }
  }

  Future<CallToolResult> _handleSetExceptionPauseMode(
      CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final mode = req.arguments!['mode'] as String;
    stderr.writeln('[mcp:set_exception_pause_mode] Setting mode to: $mode');

    try {
      try {
        await _vmService!
            .setIsolatePauseMode(_isolateId!, exceptionPauseMode: mode);
      } catch (_) {
        // Fallback for older VM Service versions
        // ignore: deprecated_member_use
        await _vmService!.setExceptionPauseMode(_isolateId!, mode);
      }
      return CallToolResult(content: [
        TextContent(text: 'Successfully set exception pause mode to: $mode')
      ]);
    } catch (e, st) {
      stderr.writeln('[mcp:set_exception_pause_mode] ERROR: $e');
      stderr.writeln('[mcp:set_exception_pause_mode] STACKTRACE: $st');
      return CallToolResult(content: [
        TextContent(text: 'Failed to set exception pause mode: $e')
      ], isError: true);
    }
  }

  Future<CallToolResult> _handleAddBreakpoint(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final filePath = req.arguments!['file_path'] as String;
    final line = (req.arguments!['line'] as num).toInt();
    final column = (req.arguments?['column'] as num?)?.toInt();
    stderr
        .writeln('[mcp:add_breakpoint] Setting breakpoint on: $filePath:$line');

    try {
      // Ensure file path is formatted as a file:// URI for the VM Service API
      final uri = filePath.startsWith('file:')
          ? filePath
          : Uri.file(filePath).toString();
      final bp = await _vmService!.addBreakpointWithScriptUri(
        _isolateId!,
        uri,
        line,
        column: column,
      );

      final bpId = bp.id ?? 'unknown';
      final md = StringBuffer('### Breakpoint Installed\n\n')
        ..writeln('- **Breakpoint ID**: `$bpId`')
        ..writeln('- **Location**: `$filePath:$line`')
        ..writeln('- **Resolved**: `${bp.resolved ?? false}`');

      return _serializeDualFormat(
        title: '### Breakpoint Set Successfully',
        markdownBody: md.toString(),
        structuredData: {
          'id': bpId,
          'file_path': filePath,
          'line': line,
          'resolved': bp.resolved ?? false,
          'raw_response': bp.json,
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:add_breakpoint] ERROR: $e');
      stderr.writeln('[mcp:add_breakpoint] STACKTRACE: $st');
      return CallToolResult(
          content: [TextContent(text: 'Failed to add breakpoint: $e')],
          isError: true);
    }
  }

  Future<CallToolResult> _handleRemoveBreakpoint(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    final breakpointId = req.arguments!['breakpoint_id'] as String;
    stderr
        .writeln('[mcp:remove_breakpoint] Removing breakpoint: $breakpointId');

    try {
      await _vmService!.removeBreakpoint(_isolateId!, breakpointId);
      return CallToolResult(content: [
        TextContent(text: 'Successfully removed breakpoint `$breakpointId`.')
      ]);
    } catch (e, st) {
      stderr.writeln('[mcp:remove_breakpoint] ERROR: $e');
      stderr.writeln('[mcp:remove_breakpoint] STACKTRACE: $st');
      return CallToolResult(
          content: [TextContent(text: 'Failed to remove breakpoint: $e')],
          isError: true);
    }
  }

  Future<CallToolResult> _handleGetNavigationStack(CallToolRequest req) async {
    if (_vmService == null || _isolateId == null) return _notConnected();
    stderr.writeln('[mcp:get_navigation_stack] Fetching navigation stack');

    try {
      final md = StringBuffer('### Navigation Stack\n\n')
        ..writeln(
            'Navigation stack inspection requires GoRouter/Navigator instrumentation.')
        ..writeln('Unable to extract route stack from VM service API.');

      return _serializeDualFormat(
        title: '### Navigation Stack',
        markdownBody: md.toString(),
        structuredData: {
          'stack': <String>[],
          'current_route': null,
          'note': 'Navigation tracking requires app-level instrumentation',
        },
      );
    } catch (e, st) {
      stderr.writeln('[mcp:get_navigation_stack] ERROR: $e');
      stderr.writeln('[mcp:get_navigation_stack] STACKTRACE: $st');
      return CallToolResult(
        content: [TextContent(text: 'Navigation stack unavailable: $e')],
        isError: true,
      );
    }
  }
}
