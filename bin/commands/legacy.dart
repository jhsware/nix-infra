import 'dart:io';
import 'package:nix_infra/cluster_node.dart';
import 'package:nix_infra/control_node.dart';
import 'package:nix_infra/docker_registry.dart';
import 'package:nix_infra/hcloud.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/provision.dart';
import 'package:nix_infra/secrets.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as path;
import 'package:dotenv/dotenv.dart';

import 'package:nix_infra/certificates.dart';

import 'package:args/args.dart';

import './utils.dart';

Future<void> legacyCommands(List<String> arguments) async {
  final pwd = Directory.current;

  exitCode = 0; // Presume success
  final parser = ArgParser()
    // ..addOption('cluster', abbr: 'c', defaultsTo: '${pwd.path}/cluster.cfg')
    ..addOption('working-dir', abbr: 'd', defaultsTo: pwd.path)
    ..addOption('ssh-key', defaultsTo: 'nixinfra')
    ..addOption('env')
    ..addFlag('batch')
    ..addFlag('debug')
    ..addFlag('help');

  // parser.addCommand('install');
  parser.addCommand('init').addFlag('no-cert-auth', negatable: false);

  parser.addCommand('provision')
    ..addOption('node-names', mandatory: true)
    ..addOption('nixos-version', defaultsTo: '23.11')
    ..addOption('machine-type', defaultsTo: 'cx22')
    ..addOption('location', defaultsTo: 'hel1')
    ..addOption('placement-group');

  parser.addCommand('update').addOption('target', mandatory: true);

  parser.addCommand('destroy')
    ..addOption('target', mandatory: true)
    ..addOption('ctrl-nodes', defaultsTo: 'etcd001 etcd002 etcd003');

  // Stand alone machine
  parser.addCommand('init-machine')
    ..addOption('target', mandatory: true)
    ..addOption('nixos-version', defaultsTo: '23.11')
    ..addOption('node-module',
        mandatory: true,
        help: 'Path to module file relative to working directory.');

  parser.addCommand('update-machine')
    ..addOption('target', mandatory: true)
    ..addOption('nixos-version', defaultsTo: '23.11')
    ..addFlag('rebuild', defaultsTo: false)
    ..addOption('node-module',
        mandatory: true,
        help: 'Path to module file relative to working directory.');

  // Cluster control node
  parser.addCommand('init-ctrl')
    ..addOption('target', defaultsTo: 'etcd001 etcd002 etcd003')
    ..addOption('nixos-version', defaultsTo: '23.11')
    ..addOption('cluster-uuid');

  parser.addCommand('update-ctrl')
    ..addOption('target', defaultsTo: 'etcd001 etcd002 etcd003')
    ..addOption('nixos-version', defaultsTo: '23.11')
    ..addFlag('rebuild', defaultsTo: false);

  // Cluster worker node
  parser.addCommand('init-node')
    ..addOption('target', mandatory: true)
    ..addOption('nixos-version', defaultsTo: '23.11')
    ..addOption('node-module',
        mandatory: true,
        help: 'Path to module file relative to working directory.')
    ..addOption('service-group',
        mandatory: true,
        help:
            'Cluster node service group this node belongs to (ingress|frontends|backends|services).')
    ..addOption('ctrl-nodes', defaultsTo: 'etcd001 etcd002 etcd003');

  parser.addCommand('update-node')
    ..addOption('target', mandatory: true)
    ..addOption('nixos-version', defaultsTo: '23.11')
    ..addOption('node-module',
        mandatory: true,
        help: 'Path to module file relative to working directory.')
    ..addOption('ctrl-nodes', defaultsTo: 'etcd001 etcd002 etcd003')
    ..addFlag('rebuild', defaultsTo: false);

  parser.addCommand('publish-image')
    ..addOption('target', mandatory: true)
    ..addOption('image-name', mandatory: true)
    ..addOption('file', mandatory: true);

  parser.addCommand('list-images').addOption('target', mandatory: true);

  parser.addCommand('deploy-apps')
    ..addOption('target', mandatory: true)
    ..addFlag('rebuild', defaultsTo: false)
    ..addFlag('overlay-network', defaultsTo: true);

  parser.addCommand('port-forward')
    ..addOption('target', mandatory: true)
    ..addOption('local-port', mandatory: true)
    ..addOption('remote-port', mandatory: true);

  parser
      .addCommand('remove-ssh-key')
      .addOption('ssh-key-name', mandatory: true);

  parser
      .addCommand('etcd')
      .addOption('ctrl-nodes', defaultsTo: 'etcd001 etcd002 etcd003');

  parser.addCommand('ssh').addOption('target', mandatory: true);
  parser.addCommand('cmd').addOption('target', mandatory: true);

  parser.addCommand('action')
    ..addOption('target', mandatory: true)
    ..addOption('app-module', mandatory: true)
    ..addOption('cmd', mandatory: true)
    // Save output as encrypted secret
    ..addOption('save-as-secret', help: 'Save output as secret')
    // Env vars will perform substitutions
    ..addMultiOption('env-vars', splitCommas: true);

  parser.addCommand('store-secret')
    ..addOption('secret', mandatory: true)
    // Save as encrypted secret
    ..addOption('save-as-secret', mandatory: true);

  final argResults = parser.parse(arguments);
  // install init provision update destroy init-ctrl init-node ssh
  final debug = argResults['debug'];

  if (argResults['help']) {
    print(parser.usage);
    exit(0);
  }

  final workingDir =
      Directory(path.normalize(path.absolute(argResults['working-dir'])));
  if (debug) echoDebug(workingDir.absolute.path);
  if (!await workingDir.exists()) {
    echo('ERROR! Working directory does not exist: ${workingDir.path}');
    exit(2);
  }

  final env = DotEnv(includePlatformEnvironment: true);
  final envFile = File(argResults['env'] ?? '${workingDir.path}/.env');
  if (await envFile.exists()) {
    if (debug) echoDebug('Loading .env from ${envFile.absolute.path}');
    env.load([envFile.path]);
  }

  final batch = argResults['batch'];
  final sshKeyName = env['SSH_KEY'] ?? argResults.command!['ssh-key'];

  // ---- INIT etc. ----
  switch (argResults.command?.name) {
    case 'init':
      areYouSure(
          'Are you sure you want to init this directory (${workingDir.path})?',
          batch);

      final noCertAuth = argResults.command!['no-cert-auth'];

      // await copyConfigurationTemplates(workingDir);

      if (!noCertAuth) {
        // TODO: Check if this is implemented:
        // NOTE: If you choose --batch you get a passwordless ssh-key
        // if you omit it, you need to provide a password
        final pwdCa =
            env['CA_PASS'] ?? readPassword(ReadPasswordEnum.caRoot, batch);
        final pwdCaInt = env['INTERMEDIATE_CA_PASS'] ??
            readPassword(ReadPasswordEnum.caIntermediate, batch);
        final certEmail =
            env['CERT_EMAIL'] ?? readInput('certificate e-mail', batch);
        final certCountryCode = env['CERT_COUNTRY_CODE'] ?? 'SE';
        final certStateProvince = env['CERT_STATE_PROVINCE'] ?? 'unknown';
        final certCompany = env['CERT_COMPANY'] ?? 'unknown';

        await createCertificateAuthority(
          workingDir,
          pwdCa,
          pwdCaInt,
          certEmail: certEmail,
          certCountryCode: certCountryCode,
          certStateProvince: certStateProvince,
          certCompany: certCompany,
          batch: batch,
          debug: debug,
        );
      }

      final sshEmail = env['SSH_EMAIL'] ?? readInput('ssh e-mail', batch);
      await createSshKeyPair(
        workingDir,
        sshEmail,
        sshKeyName,
        debug: debug,
        batch: batch,
      );

      exit(0);
  }

  if (env['HCLOUD_TOKEN'] == null) {
    echo('ERROR! env var HCLOUD_TOKEN not found');
    exit(2);
  }

  final hcloud = HetznerCloud(token: env['HCLOUD_TOKEN']!, sshKey: sshKeyName);

  // ---- COMMANDS that require cloud stuff ----
  switch (argResults.command?.name) {
    case 'provision':
      final createdNodeNames = await createNodes(
          workingDir, argResults.command!['node-names'].split(' '),
          hcloudToken: env['HCLOUD_TOKEN']!,
          sshKeyName: env['SSH_KEY'] ?? argResults.command!['ssh-key'],
          location: argResults.command!['location'],
          machineType: argResults.command!['machine-type'],
          placementGroup: argResults.command!['placement-group']);
      final createdServers = await hcloud.getServers(only: createdNodeNames);

      await clearKnownHosts(createdServers);

      await waitForServers(
        workingDir,
        createdServers,
        hcloudToken: env['HCLOUD_TOKEN']!,
        sshKeyName: sshKeyName,
      );

      await waitForSsh(createdServers);

      echo('Converting to NixOS...');
      await installNixos(
        workingDir,
        createdServers,
        nixVersion: argResults.command!['nixos-version'],
        sshKeyName: env['SSH_KEY'] ?? argResults.command!['ssh-key'],
        debug: debug,
      );
      echo('Done!');

      int triesLeft = 3;
      List<ClusterNode> failedConversions =
          await getServersWithoutNixos(workingDir, createdServers, debug: true);
      while (triesLeft-- > 0 && failedConversions.isNotEmpty) {
        echo('WARN! Some nodes are still running Ubuntu, retrying...');
        await installNixos(
          workingDir,
          failedConversions,
          nixVersion: argResults.command!['nixos-version'],
          sshKeyName: env['SSH_KEY'] ?? argResults.command!['ssh-key'],
          debug: debug,
        );
        failedConversions = await getServersWithoutNixos(
            workingDir, createdServers,
            debug: true);
      }

      if (failedConversions.isNotEmpty) {
        echo('ERROR! Some nodes are still running Ubuntu');
        exit(2);
      }
      exit(0);
    case 'update':
      echo('update not implemented yet');
      break;
    case 'destroy':
      final targets = argResults.command!['target'].split(' ');
      final nodes = await hcloud.getServers(only: targets);
      // TODO: Fix this! Perhaps set etcd node IPs as env vars on each host?
      final tmp = argResults.command!['ctrl-nodes'].split(' ');
      final ctrlNodes = await hcloud.getServers(only: tmp);

      try {
        await unregisterClusterNode(workingDir, nodes, ctrlNodes: ctrlNodes);
      } catch (_) {}
      await destroyNodes(
        workingDir,
        nodes,
        hcloudToken: env['HCLOUD_TOKEN']!,
        sshKeyName: sshKeyName,
      );
      exit(0);
    case 'init-machine':
      areYouSure('Are you sure you want to init the nodes?', batch);
      final secretsPwd =
          env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);
      final nodeNames = argResults.command!['target'].split(' ');
      // Allow passing multiple node names
      final nodes = await hcloud.getServers(only: nodeNames);
      final nodeType = argResults.command!['node-module'];
      await deployMachine(
        workingDir,
        nodes,
        nixVersion: argResults.command!['nixos-version'],
        nodeType: nodeType,
        secretsPwd: secretsPwd,
      );
      await nixosRebuild(workingDir, nodes);
      exit(0);
    case 'update-machine':
      areYouSure('Are you sure you want to update the nodes?', batch);
      final secretsPwd =
          env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);
      final nodeNames = argResults.command!['target'].split(' ');
      // Allow passing multiple node names
      final nodes = await hcloud.getServers(only: nodeNames);
      await deployMachine(
        workingDir,
        nodes,
        nixVersion: argResults.command!['nixos-version'],
        nodeType: argResults.command!['node-module'],
        secretsPwd: secretsPwd,
      );

      if (argResults.command!['rebuild']) {
        echo("Rebuilding...");
        await nixosRebuild(workingDir, nodes);
      }
      exit(0);
    case 'init-ctrl':
      areYouSure('Are you sure you want to init a control plane?', batch);

      final tmp = argResults.command!['target'].split(' ');
      final ctrlNodes = await hcloud.getServers(only: tmp);

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
        nixVersion: argResults.command!['nixos-version'],
        clusterUuid: argResults.command!['cluster-uuid'],
      );

      await nixosRebuild(workingDir, ctrlNodes);

      exit(0);
    case 'update-ctrl':
      areYouSure('Are you sure you want to update the control plane?', batch);

      final tmp = argResults.command!['target'].split(' ');
      final ctrlNodes = await hcloud.getServers(only: tmp);

      await deployControlNode(
        workingDir,
        ctrlNodes,
        nixVersion: argResults.command!['nixos-version'],
        clusterUuid: argResults.command!['cluster-uuid'],
      );

      if (argResults.command!['rebuild']) {
        await nixosRebuild(workingDir, ctrlNodes);
      }

      exit(0);
    case 'init-node':
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

      final nodeNames = argResults.command!['target'].split(' ');
      // Allow passing multiple node names
      final nodes = await hcloud.getServers(only: nodeNames);

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

      final tmp = argResults.command!['ctrl-nodes'].split(' ');
      final ctrlNodes = await hcloud.getServers(only: tmp);
      final cluster = await hcloud.getServers();

      final nodeType = argResults.command!['node-module'];
      final serviceGroups = argResults.command!['service-group']?.split(" ");

      await deployClusterNode(
        workingDir,
        cluster,
        nodes,
        nixVersion: argResults.command!['nixos-version'],
        nodeType: nodeType,
        ctrlNodes: ctrlNodes,
        secretsPwd: secretsPwd,
      );

      await nixosRebuild(workingDir, nodes);
      await triggerConfdUpdate(workingDir, nodes);

      await registerClusterNode(workingDir, nodes,
          ctrlNodes: ctrlNodes, services: serviceGroups);

      exit(0);
    case 'update-node':
      areYouSure('Are you sure you want to update the nodes?', batch);

      final secretsPwd =
          env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

      final nodeNames = argResults.command!['target'].split(' ');
      // Allow passing multiple node names
      final nodes = await hcloud.getServers(only: nodeNames);

      final tmp = argResults.command!['ctrl-nodes'].split(' ');
      final ctrlNodes = await hcloud.getServers(only: tmp);
      final cluster = await hcloud.getServers();

      await deployClusterNode(
        workingDir,
        cluster,
        nodes,
        nixVersion: argResults.command!['nixos-version'],
        nodeType: argResults.command!['node-module'],
        ctrlNodes: ctrlNodes,
        secretsPwd: secretsPwd,
      );

      if (argResults.command!['rebuild']) {
        echo("Rebuilding...");
        await nixosRebuild(workingDir, nodes);
        await triggerConfdUpdate(workingDir, nodes);
      }
      exit(0);
    case 'publish-image':
      final nodeNames = argResults.command!['target'].split(' ');
      final cluster = await hcloud.getServers();
      final nodes = await hcloud.getServers(only: nodeNames);
      await publishImageToRegistry(workingDir, cluster, nodes.first,
          file: argResults.command!['file'],
          name: argResults.command!['image-name']);
      exit(0);
    case 'list-images':
      final nodeNames = argResults.command!['target'].split(' ');
      final cluster = await hcloud.getServers();
      final nodes = await hcloud.getServers(only: nodeNames);
      await listImagesInRegistry(workingDir, cluster, nodes.first);
      exit(0);
    case 'deploy-apps':
      areYouSure('Are you sure you want to deploy apps?', batch);

      final secretsPwd =
          env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

      final hasOverlayNetwork = argResults.command!['overlay-network'];

      final nodeNames = argResults.command!['target'].split(' ');
      // Allow passing multiple node names
      final nodes = await hcloud.getServers(only: nodeNames);
      final cluster = await hcloud.getServers();

      await deployAppsOnNode(
        workingDir,
        cluster,
        nodes,
        secretsPwd: secretsPwd,
        debug: debug,
        overlayNetwork: hasOverlayNetwork,
      );

      if (argResults.command!['rebuild']) {
        await nixosRebuild(workingDir, nodes);
        // I don't believe this is needed for app updates, it should
        // be done automatically:
        // await triggerConfdUpdate(nodes);
      }

      exit(0);
    case 'gc':
      // Garbage collect Nix store
      // This isn't used yet
      echo('gc not implemented yet');
      break;
    case 'port-forward':
      final name = argResults.command!['target'] as String;
      final localPort = int.parse(argResults.command!['local-port']);
      final remotePort = int.parse(argResults.command!['remote-port']);
      final cluster = await hcloud.getServers();
      final nodes = await hcloud.getServers(only: [name]);
      if (nodes.isEmpty) {
        echo('ERROR! Node not found in cluster: $name');
        exit(2);
      }
      final node = nodes.first;
      await portForward(workingDir, cluster, node, localPort, remotePort);
      break;
    case 'ssh':
      final name = argResults.command!['target'] as String;
      final nodes = await hcloud.getServers(only: [name]);
      if (nodes.isEmpty) {
        echo('ERROR! Node not found in cluster: $name');
        exit(2);
      }
      final node = nodes.first;
      await openShellOverSsh(workingDir, node);
      exit(0);
    case 'remove-ssh-key':
      final sshKeyToRemove = argResults.command!['ssh-key-name'];
      await hcloud.removeSshKeyFromCloudProvider(workingDir, sshKeyToRemove);
      exit(0);
    case 'cmd':
      final nodeNames = argResults.command!['target'].split(' ');
      final nodes = await hcloud.getServers(only: nodeNames);
      if (nodes.isEmpty) {
        echo('ERROR! Nodes not found in cluster: $nodeNames');
        exit(2);
      }
      final cmd = argResults.command?.rest.join(' ') ?? 'uptime';
      // debug(cmd);
      final res = await Future.wait(nodes.map((node) async {
        final inp = await runCommandOverSsh(workingDir, node, cmd);
        final tmp = inp.split('\n');
        final outp = tmp.map((str) => '${node.name}: $str');
        return outp.join('\n');
      }));
      echo(res.join("\n"));
      exit(0);
    case 'etcd':
      final ctrl = argResults.command!['ctrl-nodes'].split(' ');
      final ctrlNodes = await hcloud.getServers(only: ctrl);
      if (ctrlNodes.isEmpty) {
        echo('ERROR! Nodes not found in cluster: $ctrl');
        exit(2);
      }
      final cmd = argResults.command?.rest.join(' ') ?? 'ls /';

      final node = ctrlNodes.first;
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
      echo(outp.join('\n'));
      exit(0);
    case 'action':
      final cluster = await hcloud.getServers();
      final nodeNames = argResults.command!['target'].split(' ');
      final nodes = await hcloud.getServers(only: nodeNames);
      if (nodes.isEmpty) {
        echo('ERROR! Nodes not found in cluster: $nodeNames');
        exit(2);
      }
      final appModule = argResults.command?['app-module'];
      final cmd = argResults.command?['cmd'];
      final secretNamespace = argResults.command?['save-as-secret'];
      final envVars = argResults.command?['env-vars'];
      final secretsPwd =
          env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

      if (secretNamespace == null) {
        final res = await Future.wait(nodes.map((node) async {
          final inp = await runActionScriptOverSsh(workingDir, cluster,
              target: node,
              appModule: appModule,
              cmd: cmd,
              envVars: envVars,
              debug: debug);
          final tmp = inp.split('\n');
          final outp = tmp.map((str) => '${node.name}: $str');
          return outp.join('\n');
        }));
        echo(res.join("\n"));
      } else {
        if (nodes.length > 1) {
          echo('ERROR! Cannot save multiple secrets at once');
          exit(2);
        }
        final node = nodes.first;
        final secret = await runActionScriptOverSsh(workingDir, cluster,
            target: node, appModule: appModule, cmd: cmd, envVars: envVars);
        await saveSecret(workingDir, secretsPwd, secretNamespace, secret);
        echo('Secret saved as $secretNamespace');
      }
      exit(0);
    case 'store-secret':
      final secret = argResults.command?['secret'];
      final secretNamespace = argResults.command?['save-as-secret'];
      final secretsPwd =
          env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

      await saveSecret(workingDir, secretsPwd, secretNamespace, secret);
      echo('Secret saved as $secretNamespace');
    case 'show-cert':
      // openssl x509 -in cert.pem -noout -text
      // This isn't used yet
      echo('show-cert not implemented yet');
      break;
    default:
      echo('ERROR! Command not recognised.');
      exit(2);
  }

  // final paths = argResults.rest;
  // echo(paths);
}
