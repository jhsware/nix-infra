import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nix_infra/cluster_node.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/provision.dart';
import 'package:nix_infra/ssh.dart';
import 'shared.dart';
import 'utils.dart';

class FleetCommand extends Command {
  @override
  final name = 'fleet';
  @override
  final description = 'Fleet management commands';

  FleetCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key', help: 'SSH key name')
      ..addOption('env', help: 'Path to .env file')
      ..addFlag('debug', defaultsTo: false, help: 'Verbose debug logging');

    addSubcommand(ProvisionCommand());

    addSubcommand(InitMachineCommand());
    addSubcommand(UpdateCommand());

    addSubcommand(DestroyCommand());
    addSubcommand(DeployAppsCommand());
    addSubcommand(GCCommand());
    addSubcommand(UpgradeNixOsCommand());
    addSubcommand(RollbackCommand());
    addSubcommand(SSHCommand());
    addSubcommand(CmdCommand());
    addSubcommand(PortForwardCommand());
    addSubcommand(ActionCommand());
    addSubcommand(UploadCommand());
  }
}

class InitMachineCommand extends Command {
  @override
  final name = 'init-machine';
  @override
  final description = 'Init machine';

  InitMachineCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('target', mandatory: true)
      ..addOption('node-module', mandatory: true)
      ..addOption('nixos-version', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    // final bool debug = parent?.argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String nodeType = argResults!['node-module'];
    final List<String> targets = argResults!['target'].split(' ');
    final String nixOsVersion = argResults!['nixos-version'];

    areYouSure('Are you sure you want to init the nodes?', batch);

    final secretsPwd =
        env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

    // Allow passing multiple node names
    final provider = await getProvider(workingDir, env, sshKeyName);
    final nodes = await provider.getServers(only: targets);

    await deployMachine(
      workingDir,
      nodes,
      nixVersion: nixOsVersion,
      nodeType: nodeType,
      secretsPwd: secretsPwd,
    );

    await nixosRebuild(workingDir, nodes);
  }
}

class UpdateCommand extends Command {
  @override
  final name = 'update';
  @override
  final description = 'Update machine';

  UpdateCommand() {
    argParser.addFlag('batch', defaultsTo: false);
    argParser.addOption('target', mandatory: true);
    argParser.addOption('node-module', mandatory: true);
    argParser.addOption('nixos-version', mandatory: true);
    argParser.addFlag('rebuild', defaultsTo: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    // final bool debug = parent?.argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String nodeType = argResults!['node-module'];
    final List<String> targets = argResults!['target'].split(' ');
    final String nixOsVersion = argResults!['nixos-version'];
    final bool rebuild = argResults!['rebuild'];

    areYouSure('Are you sure you want to update the nodes?', batch);
    final secretsPwd =
        env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

    // Allow passing multiple node names
    final provider = await getProvider(workingDir, env, sshKeyName);
    final nodes = await provider.getServers(only: targets);
    await deployMachine(
      workingDir,
      nodes,
      nixVersion: nixOsVersion,
      nodeType: nodeType,
      secretsPwd: secretsPwd,
    );

    if (rebuild) {
      echo("Rebuilding...");
      await nixosRebuild(workingDir, nodes);
    }
  }
}

class DestroyCommand extends Command {
  @override
  final name = 'destroy';
  @override
  final description = 'Destroy machine';

  DestroyCommand() {
    argParser.addFlag('batch', defaultsTo: false);
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');

    areYouSure('Are you sure you want to destroy these nodes?', batch);

    final provider = await getProvider(workingDir, env, sshKeyName);
    
    // Check if provider supports destroying servers
    if (!provider.supportsDestroyServer) {
      echo('WARNING: The ${provider.providerName} provider does not support destroying servers.');
      echo('For self-hosted servers, remove them manually from servers.yaml instead.');
      return;
    }

    // Allow passing multiple node names
    final nodes = await provider.getServers(only: targets);

    await destroyNodes(
      workingDir,
      nodes,
      provider: provider,
    );
  }
}

class DeployAppsCommand extends Command {
  @override
  final name = 'deploy-apps';
  @override
  final description = 'Deploy applications to machine';

  DeployAppsCommand() {
    argParser.addFlag('batch', defaultsTo: false);
    argParser.addOption('test-dir', mandatory: false);
    argParser.addOption('target', mandatory: true);
    argParser.addFlag('rebuild', defaultsTo: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);
    final testDir = argResults!['test-dir'] != null ?
        await getWorkingDirectory(argResults!['test-dir']) : null;

    final bool debug = parent?.argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');
    final bool rebuild = argResults!['rebuild'];

    areYouSure('Are you sure you want to deploy apps?', batch);

    final secretsPwd =
        env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

    // Allow passing multiple node names
    final provider = await getProvider(workingDir, env, sshKeyName);
    final nodes = await provider.getServers(only: targets);
    final cluster = await provider.getServers();

    await deployAppsOnNode(
      workingDir,
      cluster,
      nodes,
      secretsPwd: secretsPwd,
      debug: debug,
      overlayNetwork: false,
      testDir: testDir,
    );

    if (rebuild) {
      await nixosRebuild(workingDir, nodes);
      // I don't believe this is needed for app updates, it should
      // be done automatically:
      // await triggerConfdUpdate(nodes);
    }
  }
}

class PortForwardCommand extends Command {
  @override
  final name = 'port-forward';
  @override
  final description = 'Forward port from machine';

  PortForwardCommand() {
    argParser.addFlag('batch', defaultsTo: false);
    argParser.addOption('target', mandatory: true);
    argParser.addOption('local-port', mandatory: true);
    argParser.addOption('remote-port', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');
    final localPort = int.parse(argResults!['local-port']);
    final remotePort = int.parse(argResults!['remote-port']);

    final provider = await getProvider(workingDir, env, sshKeyName);

    final cluster = await provider.getServers();
    final nodes = await provider.getServers(only: targets);
    if (nodes.isEmpty) {
      echo('ERROR! Node not found in cluster: $targets');
      exit(2);
    }
    final node = nodes.first;
    await portForward(
      workingDir,
      cluster,
      node,
      localPort,
      remotePort,
      overlayNetwork: false,
    );
  }
}
