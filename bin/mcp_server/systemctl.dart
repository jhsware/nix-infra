import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/ssh.dart';
import 'mcp_tool.dart';
import 'utils/systemctl_command_parser.dart';

class SystemCtl extends McpTool {
  static const description = 'Query systemd unit status and information (read-only commands only).';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description':
          'Single node or comma separated list of nodes to run commands on.',
    },
    'options': {'type': 'string', 'description': 'Options for systemctl call'},
    'command': {
      'type': 'string',
      'description': 'Command for systemctl call. Only read-only commands are allowed: '
          'status, show, cat, help, list-units, list-sockets, list-timers, '
          'list-jobs, list-unit-files, list-dependencies, list-machines, '
          'is-active, is-enabled, is-failed, is-system-running, get-default, show-environment'
    },
    'units': {
      'type': 'string',
      'description': 'Comma separated list of units to inspect'
    },
  };

  SystemCtl({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'];
    final options = args['options'] as String?;
    final command = args['command'] as String?;
    final units = args['units'] as String?;

    // Build the command parts for validation
    final cmdParts = <String>[];
    
    if (command != null && command.isNotEmpty) {
      cmdParts.add(command);
    }
    if (units != null && units.isNotEmpty) {
      cmdParts.addAll(units.split(',').map((u) => u.trim()).where((u) => u.isNotEmpty));
    }
    if (options != null && options.isNotEmpty) {
      cmdParts.add(options);
    }

    // Validate the command using the parser
    final cmdString = cmdParts.join(' ');
    final validation = SystemctlCommandParser.validate(cmdString);
    
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

    // Build the actual command
    final cmd = ['systemctl'];
    
    if (command != null && command.isNotEmpty) {
      cmd.add(command);
    }
    if (units != null && units.isNotEmpty) {
      final Iterable<String> tmp = units.split(',').map((u) => u.trim()).where((u) => u.isNotEmpty);
      cmd.add(tmp.join(' '));
    }
    if (options != null && options.isNotEmpty) {
      cmd.add(options);
    }

    final tmpTargets = target.split(',');
    final nodes = await provider.getServers(only: tmpTargets);
    
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
