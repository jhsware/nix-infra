import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';
import 'package:nix_infra/ssh.dart';

class RemoteCommand extends McpTool {
  static const description =
      'Executes a remote command over SSH and returns the result';

  static const inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description':
          'Single node or comma separated list of nodes to run commands on.',
    },
    'command': {'type': 'string'},
  };

  RemoteCommand({
    required super.workingDir,
    required super.sshKeyName,
    required super.hcloudToken,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'];
    final command = args!['command'];

    final tmpTargets = target.split(',');
    final nodes = await hcloud.getServers(only: tmpTargets);
    
    final Iterable<Future<String>> futures = nodes
        .toList()
        .map((node) => runCommandOverSsh(workingDir, node, command));
    final result = (await Future.wait(futures)).join('\n');


    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: result,
        ),
      ],
    );
  }
}
