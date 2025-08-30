import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:nix_infra/provision.dart';
import 'package:nix_infra/secrets.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:nix_infra/hcloud.dart';

import 'utils.dart';

class ProvisionCommand extends Command {
  @override
  final name = 'provision';
  @override
  final description = 'Provision new cluster nodes';

  ProvisionCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('node-names', mandatory: true)
      ..addOption('provider')
      ..addOption('nixos-version')
      ..addOption('machine-type')
      ..addOption('location')
      ..addOption('placement-group');
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool debug = parent?.argResults!['debug'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY']!;
    final List<String> nodeNames = argResults!['node-names'].split(' ');
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final String location = argResults!['location'];
    final String machineType = argResults!['machine-type'];
    final String? placementGroup = argResults!['placement-group'];
    final String nixOsVersion = argResults!['nixos-version'];

    final createdNodeNames = await createNodes(workingDir, nodeNames,
        hcloudToken: hcloudToken,
        sshKeyName: sshKeyName,
        location: location,
        machineType: machineType,
        placementGroup: placementGroup);

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
    final createdServers = await hcloud.getServers(only: createdNodeNames);

    await clearKnownHosts(createdServers);

    await waitForServers(
      workingDir,
      createdServers,
      hcloudToken: hcloudToken,
      sshKeyName: sshKeyName,
    );

    await waitForSsh(createdServers);

    echo('Converting to NixOS... $nixOsVersion');
    await installNixos(
      workingDir,
      createdServers,
      nixVersion: nixOsVersion,
      sshKeyName: sshKeyName,
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
        nixVersion: nixOsVersion,
        sshKeyName: sshKeyName,
        debug: debug,
      );
      failedConversions =
          await getServersWithoutNixos(workingDir, createdServers, debug: true);
    }

    if (failedConversions.isNotEmpty) {
      echo('ERROR! Some nodes are still running Ubuntu');
      exit(2);
    }
  }
}

class GCCommand extends Command {
  @override
  final name = 'gc';
  @override
  final description = 'Garbage collect cluster node';

  GCCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);

    final nodes = await hcloud.getServers(only: targets);
    if (nodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    areYouSure(
        'This clears the rollback history. Are you sure you want to garbage collect?',
        batch);

    await Future.wait(nodes.map((node) async {
      final message =
          await runCommandOverSsh(workingDir, node, 'nix-collect-garbage -d');
      echoFromNode(node.name, message);
    }));
  }
}

class UpgradeCommand extends Command {
  @override
  final name = 'upgrade-nixos';
  @override
  final description = 'Upgrade cluster node';

  UpgradeCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('nix-version', mandatory: false)
      ..addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final String? nixVersion = argResults!['nix-version'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');

    areYouSure('Are you sure you want to upgrade to NixOS $nixVersion?', batch);

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);

    final nodes = await hcloud.getServers(only: targets);
    if (nodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    await Future.wait(nodes.map((node) async {
      String outp;

      outp = await runCommandOverSsh(workingDir, node, 'nixos-version');
      echoFromNode(node.name, 'Current NixOS version: $outp');

      // If we do a major upgrade we need to perform some extra steps
      if (nixVersion != null && !outp.startsWith(nixVersion)) {
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

        await sftpSend(
            sftp, '${workingDir.path}/flake.nix', '/etc/nixos/flake.nix',
            substitutions: {
              'nixVersion':
                  nixVersion, // This is neither a secret or a node specific value, should probably not be a variable
              'nodeName': node.name,
              'hwArch':
                  'x86_64-linux', // QUESTION: Should we read variables from target node?
            });

        sftp.close();
        sshClient.close();

        outp = await runCommandOverSsh(workingDir, node,
            'nix-channel --add https://nixos.org/channels/nixos-$nixVersion nixos');
        echoFromNode(node.name, outp);
      }

      // Now perform the actual update
      outp = await runCommandOverSsh(workingDir, node, 'nix-channel --update');
      echoFromNode(node.name, outp);

      outp = await runCommandOverSsh(
          workingDir, node, 'nixos-rebuild switch --fast');
      echoFromNode(node.name, outp);

      outp = await runCommandOverSsh(workingDir, node, 'nixos-version');
      echoFromNode(node.name, 'Upgraded NixOS version: $outp');
    }));
  }
}

class RollbackCommand extends Command {
  @override
  final name = 'rollback';
  @override
  final description = 'Rollback cluster node';

  RollbackCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false)
      ..addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');

    areYouSure('Are you sure you want to rollback?', batch);

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);

    final nodes = await hcloud.getServers(only: targets);
    if (nodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    await Future.wait(nodes.map((node) async {
      final message = await runCommandOverSsh(
          workingDir, node, 'nixos-rebuild switch --rollback');
      echoFromNode(node.name, message);
    }));
  }
}

class SSHCommand extends Command {
  @override
  final name = 'ssh';
  @override
  final description = 'SSH into cluster node';

  SSHCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);

    final name = argResults!['target'] as String;
    final nodes = await hcloud.getServers(only: targets);
    if (nodes.isEmpty) {
      echo('ERROR! Node not found in cluster: $name');
      exit(2);
    }
    final node = nodes.first;
    await openShellOverSsh(workingDir, node);
  }
}

class UploadCommand extends Command {
  @override
  final name = 'upload';
  @override
  final description = 'Send one or more files to target(s) over sftp.';

  UploadCommand() {
    argParser
      ..addOption('target', mandatory: true)
      ..addOption('file', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');
    final List<String> files = argResults!['file'].split(' ');

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);

    final nodes = await hcloud.getServers(only: targets);
    if (nodes.isEmpty) {
      echo('ERROR! Node(s) not found in cluster: $name');
      exit(2);
    }

    final futs = nodes.map((node) async {
      final SSHSocket connection = await waitAndGetSshConnection(node);
      final SSHClient sshClient =
          await getSshClient(workingDir, node, connection);
      final sftp = await sshClient.sftp();

      const uploadPath = '/root/uploads';

      try {
        await sftpMkDir(sftp, uploadPath);

        final queue = [];
        for (final filePath in files) {
          FileSystemEntity entity = FileSystemEntity.typeSync(filePath) ==
                  FileSystemEntityType.directory
              ? Directory(filePath)
              : File(filePath);

          final relPath = entity.path.split("/").last;
          queue.add({
            "relPath": relPath,
            "entity": entity,
          });
        }

        while (queue.isNotEmpty) {
          final item = queue.removeAt(0);
          final entity = item["entity"];
          final relPath = item["relPath"];
          if (entity is Directory) {
            queue.addAll(entity.listSync().map((e) {
              final newRelPath = "$relPath/${entity.path.split("/").last}";
              return {
                "relPath": newRelPath,
                "entity": e,
              };
            }));
            continue;
          }

          await sftpSend(sftp, entity.path, '$uploadPath/$relPath');
        }

        sftp.close();
      } finally {
        sshClient.close();
      }
    });

    await Future.wait(futs);
  }
}

class CmdCommand extends Command {
  @override
  final name = 'cmd';
  @override
  final description = 'Run command on target machine(s)';

  CmdCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);

    final nodes = await hcloud.getServers(only: targets);
    if (nodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }
    final cmd = argResults?.rest.join(' ') ?? 'uptime';

    await Future.wait(nodes.map((node) async {
      final inp = await runCommandOverSsh(workingDir, node, cmd);
      echoFromNode(node.name, inp);
    }));
  }
}

class ActionCommand extends Command {
  @override
  final name = 'action';
  @override
  final description = 'Run action on cluster node';
  bool overlayNetwork;

  ActionCommand({this.overlayNetwork = false}) {
    argParser
      ..addOption('target', mandatory: true)
      ..addOption('app-module', mandatory: true)
      ..addOption('cmd', mandatory: true)
      ..addOption('env-vars', mandatory: false)
      ..addOption('save-as-secret', mandatory: false)
      ..addFlag('batch',
          help: 'Run non-interactively using environment variables',
          defaultsTo: false);
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool debug = parent?.argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');
    final String appModule = argResults?['app-module'];
    final String cmd = argResults?['cmd'];
    final String? secretNamespace = argResults?['save-as-secret'];
    final List<String> envVars = argResults?['env-vars']?.split(',') ?? [];

    final String secretsPwd =
        env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);

    final cluster = await hcloud.getServers();
    final nodes = await hcloud.getServers(only: targets);
    if (nodes.isEmpty) {
      echo('ERROR! Nodes not found in cluster: $targets');
      exit(2);
    }

    if (secretNamespace == null) {
      await Future.wait(nodes.map((node) async {
        final message = await runActionScriptOverSsh(
          workingDir,
          cluster,
          target: node,
          appModule: appModule,
          cmd: cmd,
          envVars: envVars,
          debug: debug,
          overlayNetwork: overlayNetwork,
        );
        echoFromNode(node.name, message);
      }));
    } else {
      if (nodes.length > 1) {
        echo('ERROR! Cannot save multiple secrets at once');
        exit(2);
      }
      final node = nodes.first;
      final secret = await runActionScriptOverSsh(
        workingDir,
        cluster,
        target: node,
        appModule: appModule,
        cmd: cmd,
        envVars: envVars,
        overlayNetwork: overlayNetwork,
      );
      await saveSecret(workingDir, secretsPwd, secretNamespace, secret);
      echo('Output saved as secret: $secretNamespace');
    }
  }
}
