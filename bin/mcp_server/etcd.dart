import 'package:mcp_dart/mcp_dart.dart';
import '../commands/etcd.dart';
import 'mcp_tool.dart';

class ControlPlaneEtcd extends McpTool {
  static const description =
      'Query the etcd backend of the cluster control plane.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description': 'Control node to connect to.',
      'default': 'etcd001',
    },
    'query': {
      'type': 'string',
      'description': 'Run etcd queries using v3 API.'
    },
  };

  ControlPlaneEtcd({
    required super.workingDir,
    required super.sshKeyName,
    required super.hcloudToken,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'];
    final query = args!['query'];

    final nodes = await hcloud.getServers(only: [target]);
    final outp = await runEtcdCtlCommand(workingDir, query, nodes.first);
    final result = outp.toList().join('\n');

    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: result,
        ),
      ],
    );
  }
}
