import 'dart:io';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'package:dartssh2/dartssh2.dart';

Future<void> deployControlNode(
    Directory workingDir, Iterable<ClusterNode> ctrlNodes,
    {required String nixVersion, required String clusterUuid}) async {
  final deployments = ctrlNodes.map((node) async {
    // Update configuration.nix by adding imported configuration file
    // for control plane services such as etcd.
    final authorizedKey = await getSshKeyAsPem(workingDir, '${node.sshKeyName}.pub');

    final SSHSocket connection = await waitAndGetSshConnection(node);
    final SSHClient sshClient = await getSshClient(workingDir, node, connection);
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

    await sftpSend(sftp, '${workingDir.path}/node_types/control_node.nix',
        '/etc/nixos/control_node.nix',
        substitutions: {
          'etcdClusterToken': clusterUuid,
          'etcdCluster': ctrlNodes
              .map(
                  (node) => '{ name = "${node.name}"; ip = "${node.ipAddr}"; }')
              .join(' '),
        });

    // Create modules directory
    await sftpMkDir(sftp, '/etc/nixos/modules');

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
