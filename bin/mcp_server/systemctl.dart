import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/ssh.dart';
import 'mcp_tool.dart';

class SystemCtl extends McpTool {
  static const description = 'Query systemd journal logs.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description': 'Cluster node to run query.',
    },
    'options': {'type': 'string', 'description': 'Options for systemctl call'},
    'command': {'type': 'string', 'description': 'Command for systemctl call'},
    'units': {
      'type': 'string',
      'description': 'Comma separated list of units to inspect'
    },
  };

  SystemCtl({
    required super.workingDir,
    required super.sshKeyName,
    required super.hcloudToken,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'];
    final options = args!['options'];
    final command = args!['command'];
    final units = args!['units'];

    final cmd = ['journalctl'];
    if (units != null && units != '') {
      final Iterable<String> tmp = units.split(',');
      cmd.add(tmp.map((unit) => '-u $unit').join(' '));
    }
    if (command != null && command != '') {
      cmd.add(command);
    }
    if (options != null && options != '') {
      cmd.add(options);
    }

    final nodes = await hcloud.getServers(only: [target]);
    final result =
        await runCommandOverSsh(workingDir, nodes.first, cmd.join(' '));

    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: result,
        ),
      ],
    );
  }
}
