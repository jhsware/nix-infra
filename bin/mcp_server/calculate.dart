import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';

class Calculate extends McpTool {
  static const description = 'Perform basic arithmetic operations';
  
  static const inputSchemaProperties = {
    'operation': {
      'type': 'string',
      'enum': ['add', 'subtract', 'multiply', 'divide'],
    },
    'a': {'type': 'number'},
    'b': {'type': 'number'},
  };

  Calculate({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final operation = args!['operation'];
    final a = args['a'];
    final b = args['b'];
    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: switch (operation) {
            'add' => 'Result: ${a + b}',
            'subtract' => 'Result: ${a - b}',
            'multiply' => 'Result: ${a * b}',
            'divide' => 'Result: ${a / b}',
            _ => throw Exception('Invalid operation'),
          },
        ),
      ],
    );
  }
}
