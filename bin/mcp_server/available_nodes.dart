import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';

class ListAvailableNodes extends McpTool {
  static const description = 'Get list of available nodes, returning id, name and ipv4';

  static const Map<String,dynamic> inputSchemaProperties = {};

  ListAvailableNodes({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final nodes = await provider.getServers();

    final tmp = [];
    for (final node in nodes) {
      tmp.add('id: ${node.id}; name: ${node.name}; ip: ${node.ipAddr};');
    }
    final result = tmp.isNotEmpty ? tmp.join('\n') : 'There are no available nodes. Perhaps not created yet?';
    // final result = 'Cluster has no nodes. Perhaps not created yet?';
    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: result,
        ),
      ],
    );
  }
}
