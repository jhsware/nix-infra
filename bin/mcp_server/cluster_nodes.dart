import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';

class ListClusterNodes extends McpTool {
  static const description = 'Get list of cluster nodes, returning hetzner cloud id, name and ipv4';

  static const Map<String,dynamic> inputSchemaProperties = {};

  ListClusterNodes({
    required super.workingDir,
    required super.sshKeyName,
    required super.hcloudToken,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final nodes = await hcloud.getServers();

    final tmp = [];
    for (final node in nodes) {
      tmp.add('id: ${node.id}; name: ${node.name}; ip: ${node.ipAddr};');
    }
    final result = tmp.isNotEmpty ? tmp.join('\n') : 'Cluster has no nodes. Perhaps not created yet?';
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
