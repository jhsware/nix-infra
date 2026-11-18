import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/ssh_key_map.dart';
import 'mcp_server/server_keys.dart';
import 'mcp_server/test_environment.dart';
import 'mcp_server/test_runner.dart';
import 'mcp_server/nix_prefetch_url.dart';
import 'package:nix_infra/helpers.dart';


void main(List<String> arguments) async {
  String? projectDir;

  // Parse arguments
  for (final arg in arguments) {
    if (arg.startsWith('--project-dir=')) {
      projectDir = arg.substring('--project-dir='.length);
    }
  }

  late final Directory workingDir;
  try {
    workingDir =
        await getWorkingDirectory(projectDir ?? Directory.current.path);
  } catch (e) {
    stderr.writeln('ERROR! $e');
    exit(2);
  }

  final env = await loadEnv('.env', workingDir);

  // SSH_KEY, or a key map (SSH_KEY_MAP_PATH) with SSH_AUTH_SOCK.
  final keys = mcpKeySettingsOrExit(env, workingDir);
  final sshKeyName = keys.sshKeyName;

  // The scripts that test-runner and test-environment start get the key
  // map (as an absolute path) and the agent socket, also when they come
  // from .env (design §6.3, §14).
  final scriptEnvironment = sshAgentScriptEnvironment(env, workingDir);

  // Use ProviderFactory to create the appropriate provider
  late final InfrastructureProvider provider;
  try {
    provider = await ProviderFactory.autoDetect(
      workingDir: workingDir,
      env: env,
      sshKeyName: sshKeyName,
      sshKeyMapPath: keys.keyMapPath,
      sshAgentSocket: keys.agentSocket,
    );
  } catch (e) {
    stderr.writeln('ERROR! $e');
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

  // // *** Filesystem ***

  // final filesystem = FileSystem(
  //   workingDir: workingDir,
  //   sshKeyName: sshKeyName,
  //   provider: provider,
  //   allowedPaths: [
  //     "${workingDir.absolute.path}/__test__",
  //     "${workingDir.absolute.path}/app_modules",
  //     "${workingDir.absolute.path}/modules",
  //     "${workingDir.absolute.path}/node_types",
  //     "${workingDir.absolute.path}/configuration.nix",
  //     "${workingDir.absolute.path}/configuration.nix",
  //   ],
  // );

  // server.tool(
  //   "read-project-files",
  //   description: FileSystem.description,
  //   inputSchemaProperties: FileSystem.inputSchemaProperties,
  //   callback: filesystem.callback,
  // );

  // final filesystemEdit = FileSystemEdit(
  //   workingDir: workingDir,
  //   sshKeyName: sshKeyName,
  //   provider: provider,
  //   allowedPaths: [
  //     "${workingDir.absolute.path}/__test__",
  //     "${workingDir.absolute.path}/app_modules",
  //   ],
  // );

  // server.tool(
  //   "edit-app-module-files",
  //   description: FileSystemEdit.description,
  //   inputSchemaProperties: FileSystemEdit.inputSchemaProperties,
  //   callback: filesystemEdit.callback,
  // );

  // *** Test Runner ***

  final testRunner = TestRunner(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
    scriptEnvironment: scriptEnvironment,
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
    scriptEnvironment: scriptEnvironment,
  );

  server.tool(
    "test-environment",
    description: TestEnvironment.description,
    inputSchemaProperties: TestEnvironment.inputSchemaProperties,
    callback: testEnvronment.callback,
  );

  // *** Nix Prefetch URL ***

  final nixPrefetchUrl = NixPrefetchUrl(
    workingDir: workingDir,
    sshKeyName: sshKeyName,
    provider: provider,
  );

  server.tool(
    "nix-prefetch-url",
    description: NixPrefetchUrl.description,
    inputSchemaProperties: NixPrefetchUrl.inputSchemaProperties,
    callback: nixPrefetchUrl.callback,
  );

  server.connect(StdioServerTransport());
}
