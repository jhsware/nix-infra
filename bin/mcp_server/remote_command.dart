import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';
import 'package:nix_infra/ssh.dart';

class RemoteCommand extends McpTool {
  static const description =
      'Executes a remote command over SSH and returns the result';

  static const inputSchemaProperties = {
    'target': {'type': 'string'},
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

    final nodes = await hcloud.getServers(only: [target]);
    final result = await runCommandOverSsh(workingDir, nodes.first, command);

    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: result,
        ),
      ],
    );
  }
}
