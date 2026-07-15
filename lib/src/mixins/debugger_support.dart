import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/exception_pause_mode.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:flutter_agent_lens/src/utils/string_utils.dart';
import 'package:vm_service/vm_service.dart' hide ExceptionPauseMode;

/// Support mixin providing debugger capabilities including call stack retrieval,
/// breakpoint management, pause configuration, and expression evaluation.
base mixin DebuggerSupport on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers all debugger-related tools.
  void registerDebuggerTools() {
    registerTool(
      Tool(
        name: McpTool.getCallStack.name,
        description: 'Get call stack frames (when paused).',
        inputSchema: ObjectSchema(
          properties: {
            'limit': limitSchema(),
          },
        ),
        annotations: ToolAnnotations(
          readOnlyHint: true,
          idempotentHint: false,
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
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
        ),
      ),
      _handleSetExceptionPauseMode,
    );

    registerTool(
      Tool(
        name: McpTool.breakpoint.name,
        description: 'Manage breakpoints. '
            'Actions: add (set at file:line), remove (by ID).',
        inputSchema: ObjectSchema(
          properties: {
            'action': StringSchema(
              description: 'Action to perform: add, remove.',
            ),
            'file_path': StringSchema(
              description:
                  'The absolute path or file URI of the target source file (for add).',
            ),
            'line': IntegerSchema(
              description: 'The 1-based line number (for add).',
            ),
            'column': IntegerSchema(
              description: 'The optional 1-based column number (for add).',
            ),
            'breakpoint_id': StringSchema(
              description:
                  'The unique ID of the breakpoint to remove (for remove).',
            ),
          },
          required: ['action'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
        ),
      ),
      _handleBreakpoint,
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
            'frame_index': IntegerSchema(
              description:
                  'Optional frame index to evaluate the expression in (if the app is paused at a breakpoint).',
            ),
          },
          required: ['expression'],
        ),
        annotations: ToolAnnotations(
          readOnlyHint: false,
        ),
      ),
      _handleEvalExpression,
    );
  }

  /// Handles the get_call_stack tool request.
  Future<CallToolResult> _handleGetCallStack(CallToolRequest req) async {
    final limit = (req.arg<num>('limit'))?.toInt() ?? 20;
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
            ? await pathResolver!.resolveToAbsolutePath(scriptUri)
            : scriptUri;
        md.writeln('| $i | `$funcName` | `$resolvedPath:$line` |');
      }
    }

    return serializeDualFormat(
      title: 'Call Stack Frames',
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
  }

  /// Handles the set_exception_pause_mode tool request.
  Future<CallToolResult> _handleSetExceptionPauseMode(
      CallToolRequest req) async {
    final modeStr = req.requireArg<String>('mode');
    final mode = ExceptionPauseMode.fromString(modeStr);
    stderr.writeln(
        '[mcp:set_exception_pause_mode] Setting mode to: ${mode.value}');

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
      TextContent(
          text: 'Successfully set exception pause mode to: ${mode.value}')
    ]);
  }

  /// Handles the add_breakpoint tool request.
  Future<CallToolResult> _handleAddBreakpoint(CallToolRequest req) async {
    final filePath = req.requireArg<String>('file_path');
    final line = (req.requireArg<num>('line')).toInt();
    final column = (req.arg<num>('column'))?.toInt();
    stderr
        .writeln('[mcp:add_breakpoint] Setting breakpoint on: $filePath:$line');

    final uri =
        filePath.startsWith('file:') ? filePath : Uri.file(filePath).toString();
    final bp = await () async {
      try {
        return await vmService!.addBreakpointWithScriptUri(
          isolateId!,
          uri,
          line,
          column: column,
        );
      } on RPCError catch (e) {
        throw StateError(
            'Failed to add breakpoint at $filePath:$line. The line may not contain executable code, '
            'or the file is not loaded in the running isolate. (Details: ${e.message})');
      }
    }();

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
    );
  }

  /// Handles the remove_breakpoint tool request.
  Future<CallToolResult> _handleRemoveBreakpoint(CallToolRequest req) async {
    final breakpointId = req.requireArg<String>('breakpoint_id');
    stderr
        .writeln('[mcp:remove_breakpoint] Removing breakpoint: $breakpointId');

    try {
      await vmService!.removeBreakpoint(isolateId!, breakpointId);
    } on RPCError catch (e) {
      return CallToolResult(
        content: [
          TextContent(
              text: 'Failed to remove breakpoint `$breakpointId`: ${e.message}')
        ],
        isError: true,
      );
    }
    return CallToolResult(content: [
      TextContent(text: 'Successfully removed breakpoint `$breakpointId`.')
    ]);
  }

  /// Handles the evaluate_expression tool request.
  Future<CallToolResult> _handleEvalExpression(CallToolRequest req) async {
    final expression = req.requireArg<String>('expression');
    final frameIndex = (req.arg<num>('frame_index'))?.toInt();

    if (frameIndex != null) {
      stderr.writeln(
          '[mcp:evaluate_expression] Evaluating in frame $frameIndex: $expression');
    } else {
      stderr.writeln(
          '[mcp:evaluate_expression] Evaluating in library: $expression');
    }

    final Object res = frameIndex != null
        ? await vmService!.evaluateInFrame(isolateId!, frameIndex, expression)
        : await vmService!
            .evaluate(isolateId!, await getEvaluationLibraryId(), expression);

    final rawValStr = res is InstanceRef
        ? (res.valueAsString ?? res.toString())
        : res.toString();
    final valStr = truncateString(rawValStr, maxLength: 5000);
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

  /// Handles the breakpoint composite tool request.
  Future<CallToolResult> _handleBreakpoint(CallToolRequest req) async {
    final action = req.requireArg<String>('action');
    return switch (action) {
      'add' => _handleAddBreakpoint(req),
      'remove' => _handleRemoveBreakpoint(req),
      _ => CallToolResult(
          content: [TextContent(text: 'Unknown breakpoint action: $action')],
          isError: true,
        ),
    };
  }
}
