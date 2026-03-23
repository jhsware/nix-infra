import 'dart:convert';
import 'dart:io';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/secrets.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'package:dartssh2/dartssh2.dart';

Future<Iterable<String>> getTrustedKeys(
    Directory workingDir, String secretsPwd) async {
  final secretsDir = Directory('${workingDir.path}/secrets');
  if (!secretsDir.existsSync()) {
    return [];
  }

  List<String> trustedKeys = [];
  for (final file in secretsDir.listSync()) {
    if (file is File) {
      final filename = file.path.split('/').last;
      if (filename.startsWith('nix-store.trusted-public-keys')) {
        trustedKeys.add(await readSecret(workingDir, secretsPwd, filename));
      }
    }
  }
  return trustedKeys;
}

/// Scan a file for [%%secrets.netrc/<name>%%] patterns and return the names.
///
/// Reads the file locally and runs substitute() with empty substitutions
/// just to extract the netrc secret names. This is used by deployMachine()
/// which needs to know about netrc secrets without deploying the file.
List<String> scanForNetrcSecrets(String filePath) {
  final file = File(filePath);
  if (!file.existsSync()) return [];

  final contents = file.readAsStringSync();
  final expectedNetrcSecrets = <String>[];
  substitute(contents, {}, expectedNetrcSecrets: expectedNetrcSecrets);
  return expectedNetrcSecrets;
}

/// Bootstrap netrc credentials on a remote node.
///
/// Decrypts the specified secrets from /root/secrets/ and combines them
/// into /run/keys/combined-netrc. Then restarts the nix-daemon so it
/// picks up the netrc file via nix.settings.netrc-file which is already
/// configured in the NixOS configuration but wasn't active when the
/// daemon first started (before the netrc file existed).
///
/// This must be called AFTER the secrets have been deployed to
/// /root/secrets/ (via syncSecrets or deploySecretOnRemote).
Future<void> bootstrapNetrcOnRemote(
  SSHClient sshClient,
  String nodeName,
  List<String> netrcSecretNames, {
  bool debug = false,
}) async {
  if (netrcSecretNames.isEmpty) return;

  if (debug) echoDebug("Bootstrap netrc on $nodeName");
  if (debug) echoDebug('Netrc secrets: $netrcSecretNames');

  final decryptCmds = netrcSecretNames
      .map((name) =>
          'systemd-creds decrypt /root/secrets/$name - >> /run/keys/combined-netrc')
      .join('\n');
  await sshClient.run('''
    mkdir -p /run/keys
    rm -f /run/keys/combined-netrc
    $decryptCmds
    chmod 0400 /run/keys/combined-netrc

    # The decrypted content may be base64-encoded (nix-infra stores
    # multiline secrets as base64). Detect and decode: netrc files
    # must start with "machine" in plain text.
    NETRC_CONTENT=\$(cat /run/keys/combined-netrc)
    if ! echo "\$NETRC_CONTENT" | head -1 | grep -qF "machine"; then
      # Doesn't start with "machine" — try base64 decode
      DECODED=\$(echo "\$NETRC_CONTENT" | base64 -d 2>/dev/null || echo "")
      if echo "\$DECODED" | head -1 | grep -qF "machine"; then
        echo "\$DECODED" > /run/keys/combined-netrc
        chmod 0400 /run/keys/combined-netrc
      fi
    fi

    # Ensure nix.conf has the netrc-file setting.
    # On first deploy, the NixOS config hasn't been applied yet so
    # nix.settings.netrc-file isn't in nix.conf. We add it manually
    # so the nix-daemon can authenticate HTTPS requests.
    # After nixos-rebuild succeeds, NixOS manages nix.conf declaratively.
    NIX_CONF=\$(readlink -f /etc/nix/nix.conf || echo /etc/nix/nix.conf)
    if [ -L /etc/nix/nix.conf ]; then
      cp "\$NIX_CONF" /etc/nix/nix.conf.tmp
      rm /etc/nix/nix.conf
      mv /etc/nix/nix.conf.tmp /etc/nix/nix.conf
    fi
    if ! grep -q 'netrc-file' /etc/nix/nix.conf 2>/dev/null; then
      echo 'netrc-file = /run/keys/combined-netrc' >> /etc/nix/nix.conf
    fi

    # Restart nix-daemon so it picks up the netrc file and setting.
    systemctl restart nix-daemon
  ''');

  if (debug) echoDebug("Netrc bootstrap complete on $nodeName");
}

Future<void> deployMachine(
  Directory workingDir,
  Iterable<ClusterNode> nodes, {
  required String nixVersion,
  required String nodeType,
  required String secretsPwd,
  bool debug = false,
}) async {
  final deployments = nodes.map((node) async {
    final authorizedKey =
        await getSshKeyAsPem(workingDir, '${node.sshKeyName}.pub');

    final SSHSocket connection = await waitAndGetSshConnection(node);
    final SSHClient sshClient =
        await getSshClient(workingDir, node, connection);
    final sftp = await sshClient.sftp();

    // Deploy base NixOS configuration
    await sftpSend(sftp, '${workingDir.path}/configuration.nix',
        '/etc/nixos/configuration.nix',
        substitutions: {
          'sshKey': authorizedKey,
          'nodeName': node.name,
          'nixVersion': nixVersion,
        });

    await sftpSend(sftp, '${workingDir.path}/flake.nix', '/etc/nixos/flake.nix',
        substitutions: {
          'nixVersion':
              nixVersion, // This is neither a secret or a node specific value, should probably not be a variable
          'nodeName': node.name,
          'hwArch':
              'x86_64-linux', // QUESTION: Should we read variables from target node?
        });

    await sftpSend(
        sftp, '${workingDir.path}/$nodeType', '/etc/nixos/cluster_node.nix');

    // Create modules directory
    await sftpMkDir(sftp, '/etc/nixos/modules');
    await sftpMkDir(sftp, '/etc/nixos/app_modules');

    // Send modules to the node
    final modulesDir = Directory('${workingDir.path}/modules');
    for (final file in modulesDir.listSync()) {
      if (file is File) {
        await sftpSend(
            sftp, file.path, '/etc/nixos/modules/${file.path.split('/').last}');
      }
    }

    sftp.close();
    sshClient.close();
  });

  await Future.wait(deployments);
}


Future<void> deployClusterNode(
  Directory workingDir,
  Iterable<ClusterNode> cluster,
  Iterable<ClusterNode> nodes, {
  required String nixVersion,
  required String nodeType,
  required Iterable<ClusterNode> ctrlNodes,
  required String secretsPwd,
}) async {
  // Create list of variable substitutions
  final substitutions = Map.fromEntries(
      cluster.map((node) => MapEntry('${node.name}.ipv4', node.ipAddr)));
  final overlayMeshIps = await getOverlayMeshIps(workingDir, cluster);
  for (final entry in overlayMeshIps.entries) {
    substitutions['${entry.key}.overlayIp'] = entry.value;
  }

  // Add cache key for nix-store
  final trustedKeys = await getTrustedKeys(workingDir, secretsPwd);
  substitutions['nix-store.trusted-public-keys'] =
      "[ ${trustedKeys.map((k) => '"$k"').join(" ")} ]";

  final deployments = nodes.map((node) async {
    // Update configuration.nix by adding imported configuration file
    // for control plane services such as etcd.
    final authorizedKey =
        await getSshKeyAsPem(workingDir, '${node.sshKeyName}.pub');

    final SSHSocket connection = await waitAndGetSshConnection(node);
    final SSHClient sshClient =
        await getSshClient(workingDir, node, connection);
    final sftp = await sshClient.sftp();

    await sftpSend(sftp, '${workingDir.path}/configuration.nix',
        '/etc/nixos/configuration.nix',
        substitutions: {
          'sshKey': authorizedKey,
          'nodeName': node.name,
          'nixVersion': nixVersion,
        });

    await sftpSend(sftp, '${workingDir.path}/flake.nix', '/etc/nixos/flake.nix',
        substitutions: {
          'nixVersion':
              nixVersion, // This is neither a secret or a node specific value, should probably not be a variable
          'nodeName': node.name,
          'hwArch':
              'x86_64-linux', // QUESTION: Should we read variables from target node?
        });

    await sftpSend(
        sftp, '${workingDir.path}/$nodeType', '/etc/nixos/cluster_node.nix',
        substitutions: {
          'etcdCluster': ctrlNodes
              .map(
                  (node) => '{ name = "${node.name}"; ip = "${node.ipAddr}"; }')
              .join(' '),
        });

    // Create modules directory
    await sftpMkDir(sftp, '/etc/nixos/modules');
    await sftpMkDir(sftp, '/etc/nixos/app_modules');

    // Send modules to the node
    final modulesDir = Directory('${workingDir.path}/modules');
    for (final file in modulesDir.listSync()) {
      if (file is File) {
        await sftpSend(
            sftp, file.path, '/etc/nixos/modules/${file.path.split('/').last}');
      }
    }

    sftp.close();
    sshClient.close();
  });

  await Future.wait(deployments);
}

Future<void> deployAppsOnNode(
  Directory workingDir,
  Iterable<ClusterNode> cluster,
  Iterable<ClusterNode> nodes, {
  required String secretsPwd,
  bool debug = false,
  bool overlayNetwork = true,
  // If we are running a test, we add a test directory that contains separate node configurations
  Directory? testDir,
}) async {
  // Create list of variable substitutions
  final substitutions = Map.fromEntries(
      cluster.map((node) => MapEntry('${node.name}.ipv4', node.ipAddr)));

  if (overlayNetwork) {
    final overlayMeshIps = await getOverlayMeshIps(workingDir, cluster);
    for (final entry in overlayMeshIps.entries) {
      substitutions['${entry.key}.overlayIp'] = entry.value;
    }
  }

  // Add cache key for nix-store
  final trustedKeys = await getTrustedKeys(workingDir, secretsPwd);
  substitutions['nix-store.trusted-public-keys'] =
      "[ ${trustedKeys.map((k) => '"$k"').join(" ")} ]";

  final deployments = nodes.map((node) async {
    final SSHSocket connection = await waitAndGetSshConnection(node);
    final SSHClient sshClient =
        await getSshClient(workingDir, node, connection);
    final sftp = await sshClient.sftp();

    Map<String, String> nodeSubstitutions = Map.from(substitutions);
    nodeSubstitutions['localhost.hostname'] = node.name;
    nodeSubstitutions['localhost.ipv4'] = node.ipAddr;
    nodeSubstitutions['localhost.overlayIp'] =
        substitutions['${node.name}.overlayIp'] ??
            '-- overlayIp not found in etcd --';

    final expectedSecrets = <String>[];
    final expectedNetrcSecrets = <String>[];
    final nodeConfigFile = File(
        '${testDir == null ? workingDir.path : testDir.path}/nodes/${node.name}.nix');
    if (nodeConfigFile.existsSync()) {
      await sftpSend(
        sftp,
        nodeConfigFile.path,
        '/etc/nixos/${node.name}.nix',
        substitutions: nodeSubstitutions,
        expectedSecrets: expectedSecrets,
        expectedNetrcSecrets: expectedNetrcSecrets,
      );
    }
    await syncSecrets(
      workingDir,
      cluster,
      node,
      expectedSecrets,
      sshClient,
      secretsPwd: secretsPwd,
      debug: debug,
      overlayNetwork: overlayNetwork,
    );

    // Bootstrap netrc: secrets were deployed by syncSecrets above,
    // now decrypt and combine them for the upcoming nixos-rebuild.
    await bootstrapNetrcOnRemote(
        sshClient, node.name, expectedNetrcSecrets, debug: debug);

    // Create modules directory
    await sftpMkDir(sftp, '/etc/nixos/app_modules');

    // Send app modules to the node recursively
    final appModulesDir = Directory('${workingDir.path}/app_modules');
    final queue = appModulesDir.listSync();
    while (queue.isNotEmpty) {
      final item = queue.removeAt(0);
      final itemRelPath = item.path.replaceFirst(appModulesDir.path, '');
      if (item is File) {
        await sftpSend(sftp, item.path, '/etc/nixos/app_modules$itemRelPath');
      } else if (item is Directory) {
        await sftpMkDir(sftp, '/etc/nixos/app_modules$itemRelPath');
        queue.addAll(item.listSync());
      }
    }
    sftp.close();

    sshClient.close();

  });

  await Future.wait(deployments);
}

Future<void> registerClusterNode(
  Directory workingDir,
  Iterable<ClusterNode> nodes, {
  required Iterable<ClusterNode> ctrlNodes,
  required List<String> services,
}) async {
  final registrations = nodes.map((node) async {
    final SSHSocket connection = await waitAndGetSshConnection(node);
    final SSHClient sshClient =
        await getSshClient(workingDir, node, connection);

    final payload = {
      "name": node.name,
      "ipv4": node.ipAddr,
      "services": services
    };

    final jsonPayload = jsonEncode(payload).replaceAll('"', '\\"');
    await sshClient.run('''
      export ETCDCTL_DIAL_TIMEOUT=3s
      export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem
      export ETCDCTL_CERT=/root/certs/${node.name}-client-tls.cert.pem
      export ETCDCTL_KEY=/root/certs/${node.name}-client-tls.key.pem
      export ETCDCTL_API=3
      etcdctl --endpoints=https://${ctrlNodes.first.ipAddr}:2379 put /cluster/nodes/${node.name} "$jsonPayload"
    ''', stdout: true, stderr: true);
    sshClient.close();
    echo('Registered ${node.name} with etcd');
  });

  await Future.wait(registrations);
}

Future<void> unregisterClusterNode(
    Directory workingDir, Iterable<ClusterNode> nodes,
    {required Iterable<ClusterNode> ctrlNodes}) async {
  final registrations = nodes.map((node) async {
    final SSHSocket connection =
        await waitAndGetSshConnection(node, maxTries: 5);
    final SSHClient sshClient =
        await getSshClient(workingDir, node, connection);

    await sshClient.run('''
      export ETCDCTL_DIAL_TIMEOUT=3s
      export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem
      export ETCDCTL_CERT=/root/certs/\$(hostname)-client-tls.cert.pem
      export ETCDCTL_KEY=/root/certs/\$(hostname)-client-tls.key.pem
      export ETCDCTL_API=3
      etcdctl --endpoints=https://${ctrlNodes.first.ipAddr}:2379 del /cluster/nodes/\$(hostname)
      systemctl stop flannel
    ''');
    sshClient.close();
    echo('Unregistered ${node.name} from etcd');
  });

  await Future.wait(registrations);
}

Future<void> triggerConfdUpdate(
    Directory workingDir, Iterable<ClusterNode> nodes) async {
  final triggers = nodes.map((node) async {
    final SSHSocket connection =
        await waitAndGetSshConnection(node, maxTries: 5);
    final SSHClient sshClient =
        await getSshClient(workingDir, node, connection);

    await sshClient.run('''
      systemctl restart confd
    ''');
    sshClient.close();
    echo('Regenerated confd templates for ${node.name}');
  });

  await Future.wait(triggers);
}
