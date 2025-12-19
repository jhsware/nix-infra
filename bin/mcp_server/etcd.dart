import 'package:mcp_dart/mcp_dart.dart';
import '../commands/etcd.dart';
import 'mcp_tool.dart';
import 'utils/etcd_command_parser.dart';

class ControlPlaneEtcd extends McpTool {
  static const description =
      'Query the etcd backend of the cluster control plane (read-only operations only).';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description': 'Control node to connect to.',
      'default': 'etcd001',
    },
    'query': {
      'type': 'string',
      'description': 'Run etcd queries using v3 API. Only read-only commands are allowed: '
          'get, watch, member list, endpoint health/status/hashkv, alarm list, '
          'user get/list, role get/list, check perf/datascale, version'
    },
  };

  ControlPlaneEtcd({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  @override
  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'];
    final query = args['query'] as String?;

    if (query == null || query.trim().isEmpty) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
            text: 'Error: No query provided',
          ),
        ],
        isError: true,
      );
    }

    // Validate the command using the parser
    final validation = EtcdCommandParser.validate(query);
    
    if (!validation.isAllowed) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
            text: 'Error: Command not allowed - ${validation.reason}',
          ),
        ],
        isError: true,
      );
    }

    final nodes = await provider.getServers(only: [target]);
    
    if (nodes.isEmpty) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
            text: 'Error: Target node "$target" not found',
          ),
        ],
        isError: true,
      );
    }

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
