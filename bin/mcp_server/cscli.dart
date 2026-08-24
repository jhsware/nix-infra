import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/ssh.dart';
import 'mcp_tool.dart';
import 'utils/cscli_command_parser.dart';

class Cscli extends McpTool {
  static const description =
      'Query CrowdSec state and information (read-only commands only). '
      'Uses cscli to inspect decisions, alerts, metrics, bouncers, machines, '
      'hub items, parsers, scenarios, collections, and config.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description':
          'Single node or comma separated list of nodes to run commands on.',
    },
    'command': {
      'type': 'string',
      'description':
          'Primary cscli command. Only read-only commands are allowed: '
              'decisions, alerts, metrics, hub, bouncers, machines, lapi, capi, '
              'explain, parsers, scenarios, postoverflows, collections, config',
    },
    'subcommand': {
      'type': 'string',
      'description':
          'Subcommand for the cscli command (e.g., list, inspect, status, show). '
              'Some commands like metrics and explain do not need a subcommand.',
    },
    'options': {
      'type': 'string',
      'description':
          'Additional options for the cscli call (e.g., --output json, --limit 50, --since 2024-01-01)',
    },
  };

  Cscli({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
    super.sshConnectTimeout,
  });

  @override
  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'];
    final command = args['command'] as String?;
    final subcommand = args['subcommand'] as String?;
    final options = args['options'] as String?;

    // Build the command parts for validation
    final cmdParts = <String>[];

    if (command != null && command.isNotEmpty) {
      cmdParts.add(command);
    }
    if (subcommand != null && subcommand.isNotEmpty) {
      cmdParts.add(subcommand);
    }
    if (options != null && options.isNotEmpty) {
      cmdParts.add(options);
    }

    // Validate the command using the parser
    final cmdString = cmdParts.join(' ');
    final validation = CscliCommandParser.validate(cmdString);

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

    // Build the actual command (cscli typically needs sudo)
    final cmd = ['sudo', 'cscli'];

    if (command != null && command.isNotEmpty) {
      cmd.add(command);
    }
    if (subcommand != null && subcommand.isNotEmpty) {
      cmd.add(subcommand);
    }
    if (options != null && options.isNotEmpty) {
      cmd.add(options);
    }

    final tmpTargets = target.split(',');
    final nodes = await provider.getServers(only: tmpTargets);

    final Iterable<Future<String>> futures = nodes.toList().map((node) =>
        runCommandOverSsh(workingDir, node, cmd.join(' '),
            connectTimeout: sshConnectTimeout));
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
