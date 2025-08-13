import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';
import '../commands/etcd.dart';

class ControlPlaneEtcdPresetQueries extends McpTool {
  static const description =
      'Interact with the etcd backend of the cluster control plane using preset queries.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description': 'Control node to connect to.',
      'default': 'etcd001',
    },
    'operation': {
      'type': 'string',
      'description': 'Preset queries for etcd backend',
      'enum': [
        'list-nodes',
        'list-services',
        'list-backends',
        'list-frontends',
      ],
    },
  };

  ControlPlaneEtcdPresetQueries({
    required super.workingDir,
    required super.sshKeyName,
    required super.hcloudToken,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final operation = args!['operation'];
    final target = args!['target'];

    late String etcdCommand;
    switch (operation) {
      case 'list-nodes':
        etcdCommand = 'get /cluster/nodes --prefix';
        break;
      case 'list-services':
        etcdCommand = 'get /cluster/services --prefix';
        break;
      case 'list-backends':
        etcdCommand = 'get /cluster/backends --prefix';
        break;
      case 'list-frontends':
        etcdCommand = 'get /cluster/frontends --prefix';
    }

    final nodes = await hcloud.getServers(only: [target]);
    final outp = await runEtcdCtlCommand(workingDir, etcdCommand, nodes.first);
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
