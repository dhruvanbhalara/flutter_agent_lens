import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import '../enums/mcp_tool.dart';
import 'vm_connection_support.dart';

/// Support mixin providing debugger capabilities including call stack retrieval,
/// breakpoint management, pause configuration, and expression evaluation.
base mixin DebuggerSupport on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers all debugger-related tools.
  void registerDebuggerTools() {

    registerTool(
      Tool(
        name: McpTool.getCallStack.name,
        description:
            'Fetch the active call stack frames for the running application (when paused).',
        inputSchema: ObjectSchema(
          properties: {
            'limit': limitSchema(defaultValue: 20.0),
            'format': formatSchema,
          },
        ),
      ),
      _handleGetCallStack,
    );

    registerTool(
      Tool(
        name: McpTool.setExceptionPauseMode.name,
        description: 'Set exception pause mode (None, All, Unhandled).',
        inputSchema: ObjectSchema(
          properties: {
            'mode': StringSchema(
              description: 'The pause mode to set: None, All, or Unhandled.',
            ),
          },
          required: ['mode'],
        ),
      ),
      _handleSetExceptionPauseMode,
    );

    registerTool(
      Tool(
        name: McpTool.addBreakpoint.name,
        description: 'Install a breakpoint at a specific line in a file.',
        inputSchema: ObjectSchema(
          properties: {
            'file_path': StringSchema(
              description:
                  'The absolute path or file URI of the target source file.',
            ),
            'line': NumberSchema(
              description: 'The 1-based line number.',
            ),
            'column': NumberSchema(
              description: 'The optional 1-based column number.',
            ),
            'format': formatSchema,
          },
          required: ['file_path', 'line'],
        ),
      ),
      _handleAddBreakpoint,
    );

    registerTool(
      Tool(
        name: McpTool.removeBreakpoint.name,
        description: 'Remove an active breakpoint by its ID.',
        inputSchema: ObjectSchema(
          properties: {
            'breakpoint_id': StringSchema(
              description: 'The unique ID of the breakpoint to remove.',
            ),
          },
          required: ['breakpoint_id'],
        ),
      ),
      _handleRemoveBreakpoint,
    );

    registerTool(
      Tool(
        name: McpTool.evaluateExpression.name,
        description:
            'Evaluate a Dart expression in the context of the running app.',
        inputSchema: ObjectSchema(
          properties: {
            'expression': StringSchema(
              description: 'The Dart expression to evaluate.',
            ),
            'frame_index': NumberSchema(
              description:
                  'Optional frame index to evaluate the expression in (if the app is paused at a breakpoint).',
            ),
          },
          required: ['expression'],
        ),
      ),
      _handleEvalExpression,
    );
  }

  /// Handles the get_call_stack tool request.
  Future<CallToolResult> _handleGetCallStack(CallToolRequest req) async {
    final limit = (req.arguments?['limit'] as num?)?.toInt() ?? 20;
    stderr.writeln('[mcp:get_call_stack] Fetching stack frames (limit=$limit)');

    final stack = await vmService!.getStack(isolateId!, limit: limit);
    final frames = stack.frames ?? [];
    final md = StringBuffer('Call Stack Frames\n\n');

    if (frames.isEmpty) {
      md.writeln('No call stack frames found. The isolate may not be paused.');
    } else {
      md.writeln('| Index | Function | Location |');
      md.writeln('| :--- | :--- | :--- |');
      for (var i = 0; i < frames.length; i++) {
        final f = frames[i];
        final funcName = f.function?.name ?? 'Unknown';
        final scriptUri = f.location?.script?.uri ?? 'Unknown';
        final line = f.location?.line?.toString() ?? '?';
        final resolvedPath = pathResolver != null
            ? pathResolver!.resolveToAbsolutePath(scriptUri)
            : scriptUri;
        md.writeln('| $i | `$funcName` | `$resolvedPath:$line` |');
      }
    }

    return serializeDualFormat(
      title: 'Active Call Stack',
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
      format: req.arguments?['format'] as String?,
    );
  }

  /// Handles the set_exception_pause_mode tool request.
  Future<CallToolResult> _handleSetExceptionPauseMode(
      CallToolRequest req) async {
    final modeStr = req.arguments!['mode'] as String;
    final mode = ExceptionPauseMode.fromString(modeStr);
    stderr.writeln('[mcp:set_exception_pause_mode] Setting mode to: ${mode.value}');

    try {
      await vmService!
          .setIsolatePauseMode(isolateId!, exceptionPauseMode: mode.value);
    } catch (e) {
      stderr.writeln(
          '[mcp:debugger] setIsolatePauseMode failed: $e. Trying deprecated fallback.');
      // Fallback for older VM Service versions
      // ignore: deprecated_member_use
      await vmService!.setExceptionPauseMode(isolateId!, mode.value);
    }
    return CallToolResult(content: [
      TextContent(text: 'Successfully set exception pause mode to: ${mode.value}')
    ]);
  }

  /// Handles the add_breakpoint tool request.
  Future<CallToolResult> _handleAddBreakpoint(CallToolRequest req) async {
    final filePath = req.arguments!['file_path'] as String;
    final line = (req.arguments!['line'] as num).toInt();
    final column = (req.arguments?['column'] as num?)?.toInt();
    stderr
        .writeln('[mcp:add_breakpoint] Setting breakpoint on: $filePath:$line');

    final uri =
        filePath.startsWith('file:') ? filePath : Uri.file(filePath).toString();
    final bp = await vmService!.addBreakpointWithScriptUri(
      isolateId!,
      uri,
      line,
      column: column,
    );

    final bpId = bp.id ?? 'unknown';
    final md = StringBuffer('Breakpoint Installed\n\n')
      ..writeln('- Breakpoint ID: $bpId')
      ..writeln('- Location: $filePath:$line')
      ..writeln('- Resolved: ${bp.resolved ?? false}');

    return serializeDualFormat(
      title: 'Breakpoint Set Successfully',
      markdownBody: md.toString(),
      structuredData: {
        'id': bpId,
        'file_path': filePath,
        'line': line,
        'resolved': bp.resolved ?? false,
        'raw_response': bp.json,
      },
      format: req.arguments?['format'] as String?,
    );
  }

  /// Handles the remove_breakpoint tool request.
  Future<CallToolResult> _handleRemoveBreakpoint(CallToolRequest req) async {
    final breakpointId = req.arguments!['breakpoint_id'] as String;
    stderr
        .writeln('[mcp:remove_breakpoint] Removing breakpoint: $breakpointId');

    await vmService!.removeBreakpoint(isolateId!, breakpointId);
    return CallToolResult(content: [
      TextContent(text: 'Successfully removed breakpoint `$breakpointId`.')
    ]);
  }

  /// Handles the evaluate_expression tool request.
  Future<CallToolResult> _handleEvalExpression(CallToolRequest req) async {
    final expression = req.arguments!['expression'] as String;
    final frameIndex = (req.arguments?['frame_index'] as num?)?.toInt();

    if (frameIndex != null) {
      stderr.writeln(
          '[mcp:evaluate_expression] Evaluating in frame $frameIndex: $expression');
    } else {
      stderr.writeln(
          '[mcp:evaluate_expression] Evaluating in library: $expression');
    }

    final dynamic res;
    if (frameIndex != null) {
      res =
          await vmService!.evaluateInFrame(isolateId!, frameIndex, expression);
    } else {
      final libraryId = await getEvaluationLibraryId();
      res = await vmService!.evaluate(isolateId!, libraryId, expression);
    }

    final valStr = res is InstanceRef ? res.valueAsString : res.toString();
    final kindStr = res is InstanceRef ? res.kind : 'Unknown';
    final classStr = res is InstanceRef ? res.classRef?.name : 'Unknown';
    return CallToolResult(
      content: [
        TextContent(
            text: 'Evaluation Result\n'
                '- Kind: $kindStr\n'
                '- Value: $valStr\n'
                '- Class: $classStr')
      ],
    );
  }
}

/// Modes for pausing the execution on exceptions.
enum ExceptionPauseMode {
  /// Do not pause on any exceptions.
  none('None'),

  /// Pause on all exceptions.
  all('All'),

  /// Pause only on unhandled exceptions.
  unhandled('Unhandled');

  /// The raw String identifier used by the Dart VM Service.
  final String value;

  const ExceptionPauseMode(this.value);

  /// Resolves the enum from a raw string input, case-insensitively, defaulting to [none] if unresolved.
  static ExceptionPauseMode fromString(String modeStr) {
    return ExceptionPauseMode.values.firstWhere(
      (e) => e.value.toLowerCase() == modeStr.toLowerCase(),
      orElse: () => ExceptionPauseMode.none,
    );
  }
}
