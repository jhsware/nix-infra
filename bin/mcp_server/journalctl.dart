import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'mcp_tool.dart';

class JournalCtl extends McpTool {
  static const description = 'Query systemd journal logs.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description':
          'Single node or comma separated list of nodes to run commands on.',
    },
    'options': {'type': 'string', 'description': 'Options for journalctl call'},
    'matches': {'type': 'string', 'description': 'Matches for journalctl call'},
  };

  JournalCtl({
    required super.workingDir,
    required super.sshKeyName,
    required super.hcloudToken,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'];
    final options = args!['options'];
    final matches = args!['matches'];

    final cmd = ['systemctl'];
    if (options != null && options != '') {
      cmd.add(options);
    }
    if (matches != null && matches != '') {
      cmd.add(matches);
    }

    final tmpTargets = target.split(',');
    final nodes = await hcloud.getServers(only: tmpTargets);
    
    final Iterable<Future<String>> futures = nodes
        .toList()
        .map((node) => runCommandOverSsh(workingDir, node, cmd.join(' ')));
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
