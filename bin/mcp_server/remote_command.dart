import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';
import 'package:nix_infra/ssh.dart';
import 'utils/bash_command_parser.dart';

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

    List<String> error = [];
    List<ParsedCommand> parsed = BashCommandParser.parseCommands(command);
    for (final cmd in parsed) {
      if (blackList.contains(cmd.binary) || !whiteList.contains(cmd.binary)) {
        error.add('The command "${cmd.binary}" is forbidden');
      }
    }
    if (error.isNotEmpty) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
            text: error.join("\n"),
          ),
        ],
      );
    }

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

const blackList = [
  "rm",
  "chown",
  "chmod",
  "dd",
  "shred",
  "wipe",
  "kill",
  "killall",
  "pkill",
  "shutdown",
  "reboot",
  "halt",
  "init",
  "passwd",
  "su",
  "sudo",
  "eval",
  "exec",
  "tcpdump",
  // Data transfer and remote ops
  "rsync",
  "ssh",
  "curl",
  "wget",
];

const whiteList = [
// System Information
  "uname",
  "hostnamectl",
  "uptime",
  "who",
  "w",
  "last",
  "id",
  "whoami",

// Process Monitoring:
  "ps",
  "top",
  "htop",
  "pgrep",
  "pstree",
  "jobs",

// Memory and CPU:
  "free",
  "vmstat",
  "iostat",
  "sar",
  "mpstat",
  "nproc",
  "/proc/cpuinfo",
  "/proc/meminfo",

// Disk and Storage:
  "df",
  "du",
  "lsblk",
  "fdisk",
  "mount",
  "findmnt",
  "lsof",
  "fuser",

// Network:
  "ip",
  "ss",
  "netstat",
  "ping",
  "traceroute",
  "nslookup",
  "dig",
  "arp",
  "iptables",

// Services and Logs:
  "systemctl",
  "journalctl",
  "dmesg",
  "tail",

// File System:
  "ls",
  "find",
  "locate",
  "which",
  "whereis",
  "file",
  "stat",
  "lsattr",

// Hardware:
  "lscpu",
  "lsmem",
  "lspci",
  "lsusb",
  "lshw",
  "dmidecode",
  "sensors",

// Performance:
  "iotop",
  "iftop",
  "nethogs",
  "tcpdump",
  "strace",
  "ltrace",
  "perf",

// Environment:
  "env",
  "printenv",
  "echo",
  "ulimit",
  "cat",
];
