import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/providers/providers.dart';
import 'mcp_server/calculate.dart';
import 'mcp_server/remote_command.dart';
import 'mcp_server/available_nodes.dart';
import 'mcp_server/filesystem.dart';
import 'mcp_server/journalctl.dart';
import 'mcp_server/systemctl.dart';
import 'mcp_server/test_runner.dart';
import 'mcp_server/system_stats.dart';
import 'package:nix_infra/helpers.dart';
import 'mcp_server/utils.dart';

void main() async {
  final workingDir = await getWorkingDirectory(Directory.current.path);
  final env = await loadEnv('.env', workingDir);

  final sshKeyName = env['SSH_KEY'];

  if (sshKeyName == null) {
    echo('ERROR! env-var SSH_KEY is missing');
    exit(2);
  }

  // Use ProviderFactory to create the appropriate provider
  late final InfrastructureProvider provider;
  try {
    provider = await ProviderFactory.autoDetect(
      workingDir: workingDir,
      env: env,
      sshKeyName: sshKeyName,
    );
  } catch (e) {
    echo('ERROR! $e');
    exit(2);
  }

  McpServer server = McpServer(
    Implementation(name: "nix-infra-machine-mcp", version: "0.1.0"),
    options: ServerOptions(
      capabilities: ServerCapabilities(
        resources: ServerCapabilitiesResources(),
        tools: ServerCapabilitiesTools(),
      ),
    ),
  );

  // *** Calculate ***

  final calculate = Calculate(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "calculate",
    description: Calculate.description,
    inputSchemaProperties: Calculate.inputSchemaProperties,
    callback: calculate.callback,
  );

  // *** RemoteCommand ***

  final remoteCommand = RemoteCommand(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "remote-command",
    description: RemoteCommand.description,
    inputSchemaProperties: RemoteCommand.inputSchemaProperties,
    callback: remoteCommand.callback,
  );

  // *** ListAvailableNodes ***

  final listClusterNodes = ListAvailableNodes(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "list-available-nodes",
    description: ListAvailableNodes.description,
    inputSchemaProperties: ListAvailableNodes.inputSchemaProperties,
    callback: listClusterNodes.callback,
  );

  // *** JournalCtl ***

  final journalCtl = JournalCtl(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "journalctl",
    description: JournalCtl.description,
    inputSchemaProperties: JournalCtl.inputSchemaProperties,
    callback: journalCtl.callback,
  );

  // *** SystemCtl ***

  final systemCtl = SystemCtl(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "systemctl",
    description: SystemCtl.description,
    inputSchemaProperties: SystemCtl.inputSchemaProperties,
    callback: systemCtl.callback,
  );

  // *** Filesystem ***

  final filesystem = FileSystem(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "configuration-files",
    description: FileSystem.description,
    inputSchemaProperties: FileSystem.inputSchemaProperties,
    callback: filesystem.callback,
  );

  // *** Filesystem ***

  final testRunner = TestRunner(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "test-runner",
    description: TestRunner.description,
    inputSchemaProperties: TestRunner.inputSchemaProperties,
    callback: testRunner.callback,
  );

  // *** SystemStats ***

  final systemStats = SystemStats(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "system-stats",
    description: SystemStats.description,
    inputSchemaProperties: SystemStats.inputSchemaProperties,
    callback: systemStats.callback,
  );

  server.connect(StdioServerTransport());
}
