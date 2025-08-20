import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/ssh.dart';
import 'mcp_tool.dart';

class SystemCtl extends McpTool {
  static const description = 'Query systemd journal logs.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description':
          'Single node or comma separated list of nodes to run commands on.',
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

    final cmd = ['systemctl'];
    
    if (command != null && command != '') {
      cmd.add(command);
    }
    if (units != null && units != '') {
      final Iterable<String> tmp = units.split(',');
      cmd.add(tmp.join(' '));
    }
    if (options != null && options != '') {
      cmd.add(options);
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
