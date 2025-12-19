import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nix_infra/certificates.dart';
import 'package:nix_infra/cluster_node.dart';
import 'package:nix_infra/control_node.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/provision.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:nix_infra/providers/providers.dart';
import 'etcd.dart';
import 'shared.dart';
import 'utils.dart';

class ClusterCommand extends Command {
  @override
  final name = 'cluster';
  @override
  final description = 'Cluster management commands';

  ClusterCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key', help: 'SSH key name')
      ..addOption('env', help: 'Path to .env file')
      ..addFlag('debug', defaultsTo: false, help: 'Verbose debug logging');

    addSubcommand(ProvisionCommand());

    addSubcommand(InitCtrlCommand());
    addSubcommand(UpdateCtrlCommand());
    addSubcommand(InitNodeCommand());
    addSubcommand(UpdateNodeCommand());

    addSubcommand(DestroyCommand());
    addSubcommand(DeployAppsCommand());
    addSubcommand(GCCommand());
    addSubcommand(UpgradeNixOsCommand());
    addSubcommand(RollbackCommand());
    addSubcommand(SSHCommand());
    addSubcommand(CmdCommand());
    addSubcommand(PortForwardCommand());
    addSubcommand(ActionCommand(overlayNetwork: true));

    addSubcommand(UploadCommand());

    addSubcommand(EtcdCommand());
  }
}

class InitCtrlCommand extends Command {
  @override
  final name = 'init-ctrl';
  @override
  final description = 'Initialize control nodes';

  InitCtrlCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('target', mandatory: true)
      ..addOption('nixos-version', mandatory: true)
      ..addOption('cluster-uuid', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool debug = parent?.argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');
    final String nixOsVersion = argResults!['nixos-version'];
    final String clusterUuid = argResults!['cluster-uuid'];

    areYouSure('Are you sure you want to init a control plane?', batch);

    final provider = await getProvider(workingDir, env, sshKeyName);

    final ctrlNodes = await provider.getServers(only: targets);

    final pwdCaInt = env['INTERMEDIATE_CA_PASS'] ??
        readPassword(ReadPasswordEnum.caIntermediate, batch);

    final certEmail =
        env['CERT_EMAIL'] ?? readInput('certificate e-mail', batch);
    final certCountryCode = env['CERT_COUNTRY_CODE'] ?? 'SE';
    final certStateProvince = env['CERT_STATE_PROVINCE'] ?? 'unknown';
    final certCompany = env['CERT_COMPANY'] ?? 'unknown';

    await generateCerts(
      workingDir,
      ctrlNodes,
      [CertType.tls, CertType.peer],
      passwordIntermediateCa: pwdCaInt,
      certEmail: certEmail,
      certCountryCode: certCountryCode,
      certStateProvince: certStateProvince,
      certCompany: certCompany,
      batch: batch,
      debug: debug,
    );

    await deployEtcdCertsOnClusterNode(
        workingDir, ctrlNodes, [CertType.tls, CertType.peer],
        debug: debug);

    await deployControlNode(
      workingDir,
      ctrlNodes,
      nixVersion: nixOsVersion,
      clusterUuid: clusterUuid,
    );

    await nixosRebuild(workingDir, ctrlNodes);
  }
}

class UpdateCtrlCommand extends Command {
  @override
  final name = 'update-ctrl';
  @override
  final description = 'Update control nodes';

  UpdateCtrlCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addFlag('rebuild', defaultsTo: false)
      ..addOption('target', mandatory: true)
      ..addOption('nixos-version', mandatory: true)
      ..addOption('cluster-uuid', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> targets = argResults!['target'].split(' ');
    final String nixOsVersion = argResults!['nixos-version'];
    final String clusterUuid = argResults!['cluster-uuid'];

    areYouSure('Are you sure you want to update the control plane?', batch);

    final provider = await getProvider(workingDir, env, sshKeyName);

    final ctrlNodes = await provider.getServers(only: targets);

    await deployControlNode(
      workingDir,
      ctrlNodes,
      nixVersion: nixOsVersion,
      clusterUuid: clusterUuid,
    );

    if (argResults!['rebuild']) {
      await nixosRebuild(workingDir, ctrlNodes);
    }
  }
}

class InitNodeCommand extends Command {
  @override
  final name = 'init-node';
  @override
  final description = 'Initialize cluster node';

  InitNodeCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('ctrl-nodes')
      ..addOption('target', mandatory: true)
      ..addOption('node-module', mandatory: true)
      ..addOption('service-group', mandatory: false)
      ..addOption('nixos-version', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool debug = parent?.argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> ctrlNodeNames =
        argResults!['ctrl-nodes']?.split(' ') ?? env['CTRL_NODES']?.split(' ');
    final List<String> targets = argResults!['target'].split(' ');
    final String nodeType = argResults!['node-module'];
    final String nixOsVersion = argResults!['nixos-version'];
    final List<String> serviceGroups = argResults!['service-group']?.split(" ");

    areYouSure('Are you sure you want to init the nodes?', batch);

    final secretsPwd =
        env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);
    final pwdCaInt = env['INTERMEDIATE_CA_PASS'] ??
        readPassword(ReadPasswordEnum.caIntermediate, batch);

    final certEmail =
        env['CERT_EMAIL'] ?? readInput('certificate e-mail', batch);
    final certCountryCode = env['CERT_COUNTRY_CODE'] ?? 'SE';
    final certStateProvince = env['CERT_STATE_PROVINCE'] ?? 'unknown';
    final certCompany = env['CERT_COMPANY'] ?? 'unknown';

    // Allow passing multiple node names
    final provider = await getProvider(workingDir, env, sshKeyName);
    final nodes = await provider.getServers(only: targets);

    await generateCerts(
      workingDir,
      nodes,
      [CertType.tls],
      passwordIntermediateCa: pwdCaInt,
      certEmail: certEmail,
      certCountryCode: certCountryCode,
      certStateProvince: certStateProvince,
      certCompany: certCompany,
      batch: batch,
      debug: debug,
    );

    await deployEtcdCertsOnClusterNode(workingDir, nodes, [CertType.tls],
        debug: debug);

    final ctrlNodes = await provider.getServers(only: ctrlNodeNames);
    final cluster = await provider.getServers();

    await deployClusterNode(
      workingDir,
      cluster,
      nodes,
      nixVersion: nixOsVersion,
      nodeType: nodeType,
      ctrlNodes: ctrlNodes,
      secretsPwd: secretsPwd,
    );

    await nixosRebuild(workingDir, nodes);
    await triggerConfdUpdate(workingDir, nodes);

    await registerClusterNode(workingDir, nodes,
        ctrlNodes: ctrlNodes, services: serviceGroups);
  }
}

class UpdateNodeCommand extends Command {
  @override
  final name = 'update-node';
  @override
  final description = 'Update cluster node';

  UpdateNodeCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addFlag('rebuild', defaultsTo: false)
      ..addOption('ctrl-nodes')
      ..addOption('target', mandatory: true)
      ..addOption('node-module', mandatory: true)
      ..addOption('nixos-version', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> ctrlNodeNames =
        argResults!['ctrl-nodes']?.split(' ') ?? env['CTRL_NODES']?.split(' ');
    final List<String> targets = argResults!['target'].split(' ');
    final String secretsPwd =
        env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);
    final String nixOsVersion = argResults!['nixos-version'];
    final String nodeType = argResults!['node-module'];
    final bool rebuild = argResults!['rebuild'];

    areYouSure('Are you sure you want to update the nodes?', batch);

    // Allow passing multiple node names
    final provider = await getProvider(workingDir, env, sshKeyName);
    final nodes = await provider.getServers(only: targets);

    final ctrlNodes = await provider.getServers(only: ctrlNodeNames);
    final cluster = await provider.getServers();

    await deployClusterNode(
      workingDir,
      cluster,
      nodes,
      nixVersion: nixOsVersion,
      nodeType: nodeType,
      ctrlNodes: ctrlNodes,
      secretsPwd: secretsPwd,
    );

    if (rebuild) {
      echo("Rebuilding...");
      await nixosRebuild(workingDir, nodes);
      await triggerConfdUpdate(workingDir, nodes);
    }
  }
}

class DestroyCommand extends Command {
  @override
  final name = 'destroy';
  @override
  final description = 'Destroy cluster node';

  DestroyCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('ctrl-nodes')
      ..addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final List<String> ctrlNodeNames =
        argResults!['ctrl-nodes']?.split(' ') ?? env['CTRL_NODES']?.split(' ');
    final List<String> targets = argResults!['target'].split(' ');

    areYouSure('Are you sure you want to destroy these nodes?', batch);

    final provider = await getProvider(workingDir, env, sshKeyName);
    final ctrlNodes = await provider.getServers(only: ctrlNodeNames);
    final nodes = await provider.getServers(only: targets);

    await unregisterClusterNode(workingDir, nodes, ctrlNodes: ctrlNodes)
        .catchError((_) {});

    // Check if provider supports destroying servers
    if (!provider.supportsDestroyServer) {
      echo('WARNING: The ${provider.providerName} provider does not support destroying servers.');
      echo('For self-hosted servers, remove them manually from servers.yaml instead.');
      echo('Node unregistered from cluster successfully.');
      return;
    }

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
  final description = 'Deploy applications to cluster node';

  DeployAppsCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addFlag('rebuild', defaultsTo: false)
      ..addOption('test-dir', mandatory: false)
      ..addOption('target', mandatory: true);
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
      overlayNetwork: true,
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
  final description = 'Forward port from cluster node';

  PortForwardCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('target', mandatory: true)
      ..addOption('local-port', mandatory: true)
      ..addOption('remote-port', mandatory: true);
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
      overlayNetwork: true,
    );
  }
}

// class EtcdCommand extends Command {
//   @override
//   final name = 'etcd';
//   @override
//   final description = 'Run etcd command';

//   EtcdCommand() {
//     argParser
//       ..addOption('target', mandatory: true)
//       ..addOption('ctrl-nodes');
//   }

//   @override
//   void run() async {
//     final workingDir =
//         await getWorkingDirectory(parent?.argResults!['working-dir']);
//     final env = await loadEnv(parent?.argResults!['env'], workingDir);

//     final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
//     final List<String> ctrlNodeNames =
//         argResults!['ctrl-nodes']?.split(' ') ?? env['CTRL_NODES']?.split(' ');
//     final String cmd = argResults!.rest.join(' ');

//     final provider = await getProvider(workingDir, env, sshKeyName);

//     final ctrlNodes = await provider.getServers(only: ctrlNodeNames);
//     if (ctrlNodes.isEmpty) {
//       echo('ERROR! Nodes not found in cluster: $ctrlNodeNames');
//       exit(2);
//     }

//     final node = ctrlNodes.first;
//     final cmdScript = [
//       'export ETCDCTL_DIAL_TIMEOUT=3s',
//       'export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem',
//       'export ETCDCTL_CERT=/root/certs/${node.name}-client-tls.cert.pem',
//       'export ETCDCTL_KEY=/root/certs/${node.name}-client-tls.key.pem',
//       'export ETCDCTL_API=3',
//       'etcdctl $cmd',
//     ].join('\n');

//     final inp = await runCommandOverSsh(workingDir, node, cmdScript);
//     echoFromNode(node.name, inp);
//   }
// }
