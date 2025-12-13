import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import './utils.dart';
import './shared.dart';

Future<Iterable<String>> runEtcdCtlCommand(
    Directory workingDir, String cmd, ClusterNode node) async {
  final cmdScript = [
    'export ETCDCTL_DIAL_TIMEOUT=3s',
    'export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem',
    'export ETCDCTL_CERT=/root/certs/${node.name}-client-tls.cert.pem',
    'export ETCDCTL_KEY=/root/certs/${node.name}-client-tls.key.pem',
    'export ETCDCTL_API=3',
    'etcdctl $cmd',
  ].join('\n');
  final inp = await runCommandOverSsh(workingDir, node, cmdScript);
  final tmp = inp.split('\n');
  final outp = tmp.map((str) => '${node.name}: $str');
  return outp;
}

class EtcdCommand extends Command {
  @override
  final name = 'etcd';
  @override
  final description = 'Manage SSH keys for infrastructure access';

  EtcdCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd', defaultsTo: '.', help: 'Directory to store SSH keys')
      ..addOption('ssh-key', mandatory: false)
      ..addOption('env', help: 'Path to environment file');

    addSubcommand(EtcdctlCommand());
    addSubcommand(ListNodesCommand());
    addSubcommand(ListServicesCommand());
    addSubcommand(ListBackendsCommand());
    addSubcommand(ListFrontendsCommand());
    addSubcommand(ShowNetworkCommand());
  }
}

class EtcdctlCommand extends Command {
  @override
  final name = 'ctl';
  @override
  final description = 'Run a command with etcdctl';

  EtcdctlCommand() {
    
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String? cmd = argResults?.rest.join(' ');
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');

    if (cmd == null) {
      echo('ERROR! No command provided');
      exit(2);
    }

    final provider = await getProvider(workingDir, env, sshKeyName);
    final ctrlNodes = await provider.getServers(only: targets);

    if (ctrlNodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    final outp = await runEtcdCtlCommand(workingDir, cmd, ctrlNodes.first);
    echo(outp.join('\n'));
  }
}

class ListNodesCommand extends Command {
  @override
  final name = 'nodes';
  @override
  final description = 'List nodes registered with etcd';

  ListNodesCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');

    final provider = await getProvider(workingDir, env, sshKeyName);
    final ctrlNodes = await provider.getServers(only: targets);

    if (ctrlNodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    final cmd = 'get /cluster/nodes --prefix';
    final outp = await runEtcdCtlCommand(workingDir, cmd, ctrlNodes.first);
    echo(outp.join('\n'));
  }
}

class ListServicesCommand extends Command {
  @override
  final name = 'services';
  @override
  final description = 'List services registered with etcd';

  ListServicesCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');

    final provider = await getProvider(workingDir, env, sshKeyName);
    final ctrlNodes = await provider.getServers(only: targets);

    if (ctrlNodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    final cmd = 'get /cluster/services --prefix';
    final outp = await runEtcdCtlCommand(workingDir, cmd, ctrlNodes.first);
    echo(outp.join('\n'));
  }
}

class ListBackendsCommand extends Command {
  @override
  final name = 'backends';
  @override
  final description = 'List backends registered with etcd';

  ListBackendsCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');

    final provider = await getProvider(workingDir, env, sshKeyName);
    final ctrlNodes = await provider.getServers(only: targets);

    if (ctrlNodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    final cmd = 'get /cluster/backends --prefix';
    final outp = await runEtcdCtlCommand(workingDir, cmd, ctrlNodes.first);
    echo(outp.join('\n'));
  }
}

class ListFrontendsCommand extends Command {
  @override
  final name = 'frontends';
  @override
  final description = 'List frontends registered with etcd';

  ListFrontendsCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');

    final provider = await getProvider(workingDir, env, sshKeyName);
    final ctrlNodes = await provider.getServers(only: targets);

    if (ctrlNodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    final cmd = 'get /cluster/frontends --prefix';
    final outp = await runEtcdCtlCommand(workingDir, cmd, ctrlNodes.first);
    echo(outp.join('\n'));
  }
}

class ShowNetworkCommand extends Command {
  @override
  final name = 'network';
  @override
  final description = 'List frontends registered with etcd';

  ShowNetworkCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');

    final provider = await getProvider(workingDir, env, sshKeyName);
    final ctrlNodes = await provider.getServers(only: targets);

    if (ctrlNodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    final cmd = 'get /coreos.com --prefix';
    final outp = await runEtcdCtlCommand(workingDir, cmd, ctrlNodes.first);
    echo(outp.join('\n'));
  }
}
