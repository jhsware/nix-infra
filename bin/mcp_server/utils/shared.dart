import 'package:mcp_dart/mcp_dart.dart';

CallToolResult callToolText(String text) {
  return CallToolResult.fromContent(content: [TextContent(text: text)]);
}
