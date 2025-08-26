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

Future<void> deployMachine(
  Directory workingDir,
  Iterable<ClusterNode> nodes, {
  required String nixVersion,
  required String nodeType,
  required String secretsPwd,
}) async {
  // Create list of variable substitutions
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
        sftp,
        '${workingDir.path}/$nodeType',
        '/etc/nixos/cluster_node.nix',
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
    nodeSubstitutions['localhost.ipv4'] = node.ipAddr;
    nodeSubstitutions['localhost.overlayIp'] =
        substitutions['${node.name}.overlayIp'] ??
            '-- overlayIp not found in etcd --';

    final expectedSecrets = <String>[];
    final nodeConfigFile = File('${testDir == null ? workingDir.path : testDir.path}/nodes/${node.name}.nix');
    if (nodeConfigFile.existsSync()) {
      await sftpSend(
        sftp,
        nodeConfigFile.path,
        '/etc/nixos/${node.name}.nix',
        substitutions: nodeSubstitutions,
        expectedSecrets: expectedSecrets,
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
