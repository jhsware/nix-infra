import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_server/calculate.dart';
import 'mcp_server/remote_command.dart';
import 'mcp_server/cluster_nodes.dart';
import 'mcp_server/etcd.dart';
import 'mcp_server/filesystem.dart';
import 'mcp_server/journalctl.dart';
import 'mcp_server/systemctl.dart';
import 'mcp_server/test_runner.dart';
import 'package:nix_infra/helpers.dart';
import 'mcp_server/utils.dart';

void main() async {
  final workingDir = await getWorkingDirectory(Directory.current.path);
  final env = await loadEnv('.env', workingDir);

  final sshKeyName = env['SSH_KEY'];
  final hcloudToken = env['HCLOUD_TOKEN'];

  if (sshKeyName == null) {
    echo('ERROR! env-var SSH_KEY is missing');
    exit(2);
  }

  if (hcloudToken == null) {
    echo('ERROR! env-var HCLOUD_TOKEN is missing');
    exit(2);
  }

  McpServer server = McpServer(
    Implementation(name: "nix-infra-cluster-mcp", version: "0.1.0"),
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
    hcloudToken: hcloudToken,
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
    hcloudToken: hcloudToken,
  );

  server.tool(
    "remote-command",
    description: RemoteCommand.description,
    inputSchemaProperties: RemoteCommand.inputSchemaProperties,
    callback: remoteCommand.callback,
  );

  // *** ListClusterNodes ***

  final listClusterNodes = ListClusterNodes(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    hcloudToken: hcloudToken,
  );

  server.tool(
    "list-cluster-nodes",
    description: ListClusterNodes.description,
    inputSchemaProperties: ListClusterNodes.inputSchemaProperties,
    callback: listClusterNodes.callback,
  );

  // *** ControlPlaneEtcd ***

  final controlPlaneEtcd = ControlPlaneEtcd(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    hcloudToken: hcloudToken,
  );

  server.tool(
    "etcd",
    description: ControlPlaneEtcd.description,
    inputSchemaProperties: ControlPlaneEtcd.inputSchemaProperties,
    callback: controlPlaneEtcd.callback,
  );

  // *** JournalCtl ***

  final journalCtl = JournalCtl(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    hcloudToken: hcloudToken,
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
    hcloudToken: hcloudToken,
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
    hcloudToken: hcloudToken,
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
    hcloudToken: hcloudToken,
  );

  server.tool(
    "test-runner",
    description: TestRunner.description,
    inputSchemaProperties: TestRunner.inputSchemaProperties,
    callback: testRunner.callback,
  );

  server.connect(StdioServerTransport());
}
