import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/ssh.dart';
import 'mcp_tool.dart';
import 'utils/journalctl_command_parser.dart';

class JournalCtl extends McpTool {
  static const description = 'Query systemd journal logs (read-only operations only).';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description':
          'Single node or comma separated list of nodes to run commands on.',
    },
    'options': {
      'type': 'string',
      'description': 'Options for journalctl call. Common options: '
          '-u/--unit (filter by unit), -n/--lines (number of lines), '
          '-f/--follow (follow logs), -p/--priority (filter by priority), '
          '-S/--since (since time), -U/--until (until time), '
          '-b/--boot (specific boot), -o/--output (output format), '
          '--no-pager, -r/--reverse, -k/--dmesg (kernel messages)'
    },
    'matches': {
      'type': 'string', 
      'description': 'Field matches for journalctl (e.g., _SYSTEMD_UNIT=nginx.service, SYSLOG_IDENTIFIER=sudo)'
    },
  };

  JournalCtl({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'];
    final options = args!['options'] as String?;
    final matches = args!['matches'] as String?;

    // Build the command parts for validation
    final cmdParts = <String>[];
    
    if (options != null && options.isNotEmpty) {
      cmdParts.add(options);
    }
    if (matches != null && matches.isNotEmpty) {
      cmdParts.add(matches);
    }

    // Validate the command using the parser
    final cmdString = cmdParts.join(' ');
    final validation = JournalctlCommandParser.validate(cmdString);
    
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
    final cmd = ['journalctl'];
    if (options != null && options.isNotEmpty) {
      cmd.add(options);
    }
    if (matches != null && matches.isNotEmpty) {
      cmd.add(matches);
    }

    final tmpTargets = target.split(',');
    final nodes = await provider.getServers(only: tmpTargets);
    
    if (nodes.isEmpty) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
            text: 'Error: No nodes found matching "$target"',
          ),
        ],
        isError: true,
      );
    }

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
