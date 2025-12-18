import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/providers/providers.dart';
import 'mcp_server/calculate.dart';
import 'mcp_server/filesystem.dart';
import 'mcp_server/filesystem_edit.dart';
import 'mcp_server/test_environment.dart';
import 'mcp_server/test_runner.dart';
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
    Implementation(name: "nix-infra-dev-mcp", version: "0.1.0"),
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

  // *** Filesystem ***

  final filesystem = FileSystem(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
    allowedPaths: [
      "${workingDir.absolute.path}/__test__",
      "${workingDir.absolute.path}/app_modules",
      "${workingDir.absolute.path}/modules",
      "${workingDir.absolute.path}/node_types",
      "${workingDir.absolute.path}/configuration.nix",
      "${workingDir.absolute.path}/configuration.nix",
    ],
  );

  server.tool(
    "read-project-files",
    description: FileSystem.description,
    inputSchemaProperties: FileSystem.inputSchemaProperties,
    callback: filesystem.callback,
  );

  final filesystemEdit = FileSystemEdit(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
    allowedPaths: [
      "${workingDir.absolute.path}/__test__",
      "${workingDir.absolute.path}/app_modules",
    ],
  );

  server.tool(
    "edit-app-module-files",
    description: FileSystemEdit.description,
    inputSchemaProperties: FileSystemEdit.inputSchemaProperties,
    callback: filesystemEdit.callback,
  );

  // *** Test Runner ***

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

  final testEnvronment = TestEnvironment(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "test-environment",
    description: TestEnvironment.description,
    inputSchemaProperties: TestEnvironment.inputSchemaProperties,
    callback: testEnvronment.callback,
  );

  server.connect(StdioServerTransport());
}
