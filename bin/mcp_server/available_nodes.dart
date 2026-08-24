import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';

class ListAvailableNodes extends McpTool {
  static const description =
      'Get list of available nodes, returning id, name, ipv4 and vpn. '
      'If a node has "vpn" set, that VPN connection must be active on this '
      'machine for ssh to reach the node. If ssh to such a node fails or '
      'times out, ask the user to start the named VPN connection, then retry.';

  static const Map<String,dynamic> inputSchemaProperties = {};

  ListAvailableNodes({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  @override
  Future<CallToolResult> callback({args, extra}) async {

    final nodes = await provider.getServers();

    final tmp = [];
    for (final node in nodes) {
      final vpn = node.requiresVpn ? ' vpn: ${node.vpn};' : '';
      tmp.add('id: ${node.id}; name: ${node.name}; ip: ${node.ipAddr};$vpn');
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
