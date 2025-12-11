import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/ssh.dart';
import 'mcp_tool.dart';
import 'utils/system_stats_commands.dart';

class SystemStats extends McpTool {
  static const description = '''Query system statistics from nodes. Returns compact, structured output optimized for AI analysis.

Operations:
- health: Quick overview (load, cpu, memory, swap, pressure, uptime)
- disk-io: Disk I/O statistics (read/write rates, utilization, latency)
- memory: Detailed memory stats (usage, buffers, cache, paging, swap activity)
- network: Network interface stats (rx/tx rates, errors, connections)
- disk-usage: Filesystem usage with threshold warnings
- processes: Top resource consumers (by CPU, memory, I/O)
- all: Run all operations at once''';

  static const Map<String, dynamic> inputSchemaProperties = {
    'target': {
      'type': 'string',
      'description':
          'Single node or comma separated list of nodes to query.',
    },
    'operation': {
      'type': 'string',
      'description': 'Operation to perform: health, disk-io, memory, network, disk-usage, processes, or all',
      'enum': ['all', 'health', 'disk-io', 'memory', 'network', 'disk-usage', 'processes'],
      'default': 'health',
    },
  };

  SystemStats({
    required super.workingDir,
    required super.sshKeyName,
    required super.hcloudToken,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final target = args!['target'] as String?;
    final operation = (args!['operation'] as String?) ?? 'health';

    if (target == null || target.trim().isEmpty) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
            text: 'Error: No target specified',
          ),
        ],
        isError: true,
      );
    }

    // Validate the operation
    final validation = SystemStatsCommandParser.validate(operation);
    
    if (!validation.isAllowed) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
            text: 'Error: ${validation.reason}',
          ),
        ],
        isError: true,
      );
    }

    // Get the command to run (hardcoded, no user input)
    final command = SystemStatsCommands.getCommand(validation.parsedCommand!.operation);
    
    if (command == null) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
            text: 'Error: Unknown operation "${validation.parsedCommand!.operation}"',
          ),
        ],
        isError: true,
      );
    }

    final tmpTargets = target.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    final nodes = await hcloud.getServers(only: tmpTargets);
    
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

    // Run command on all nodes in parallel
    final List<Future<String>> futures = nodes.map((node) async {
      try {
        final output = await runCommandOverSsh(workingDir, node, command);
        return '--- ${node.name} (${node.ipAddr}) ---\n$output';
      } catch (e) {
        return '--- ${node.name} (${node.ipAddr}) ---\nError: $e';
      }
    }).toList();

    final results = await Future.wait(futures);
    final result = results.join('\n\n');

    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: result,
        ),
      ],
    );
  }
}
