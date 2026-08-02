import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_agent_lens/src/enums/mcp_tool.dart';
import 'package:flutter_agent_lens/src/extensions/call_tool_request_x.dart';
import 'package:flutter_agent_lens/src/mixins/vm_connection_support.dart';
import 'package:vm_service/vm_service.dart';

/// Support mixin providing tool for driving list scroll animations gesture.
base mixin ScrollGestureSupport
    on MCPServer, ToolsSupport, VmConnectionSupport {
  /// Registers scroll gesture control tools.
  void registerScrollGestureTools() {
    registerTool(
      Tool(
        name: McpTool.triggerScrollGesture.name,
        description: 'Simulate scroll gesture.',
        inputSchema: ObjectSchema(
          properties: {
            'scrollControllerExpression': StringSchema(
              description:
                  'Dart expression that evaluates to the ScrollController (e.g., PrimaryScrollController.of(primaryFocus!.context)).',
            ),
            'offset': NumberSchema(
              description: 'Pixel offset to scroll to (default: 500.0).',
            ),
          },
          required: ['scrollControllerExpression'],
        ),
      ),
      _handleScrollGesture,
    );
  }

  /// Handles the trigger_scroll_gesture tool request.
  Future<CallToolResult> _handleScrollGesture(CallToolRequest req) async {
    final controller = req.arg<String>('scrollControllerExpression') ??
        req.requireArg<String>('scroll_controller_expression');
    final offset = req.doubleArg('offset', defaultValue: 500.0)!;
    stderr.writeln(
        '[mcp:scroll_gesture] Controller: $controller, offset: $offset');

    final script = '$controller.animateTo('
        '$offset, '
        'duration: const Duration(milliseconds: 300), '
        'curve: Curves.easeInOut, '
        ')';

    final libraryId = await getEvaluationLibraryId();
    final eval = await vmService!.evaluate(isolateId!, libraryId, script);
    final evalStr = eval is InstanceRef ? eval.valueAsString : eval.toString();
    return CallToolResult(
      content: [
        TextContent(
            text:
                'Scroll gesture driven successfully. Evaluation result: `$evalStr`')
      ],
    );
  }
}
