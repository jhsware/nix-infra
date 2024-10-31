import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';

import 'package:nix_infra/hcloud.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'package:process_run/shell.dart';

Future<List<String>> createNodes(
  Directory workingDir,
  List<String> nodeNames, {
  required String hcloudToken,
  required String location,
  required String sshKeyName,
  required String machineType,
}) async {
  final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
  await hcloud.addSshKeyToCloudProvider(workingDir, sshKeyName);

  echo('************* SPAWNING NODES *************');
  //
  // 1. Find existing nodes by checking hcloud server list
  final existingNodes = (await hcloud.getServers()).toList();
  final createdNodes = <String>[];

  for (final name in nodeNames) {
    if (existingNodes.any((node) => node.name == name)) {
      echo('Node $name already exists, skipping!');
      continue;
    } else {
      echo("Node: $name doesn't exist, creating...");
      await hcloud.createServer(
        name,
        machineType,
        location,
        sshKeyName,
      );
      createdNodes.add(name);
    }
  }
  return createdNodes;
}

Future<void> destroyNodes(Directory workingDir, Iterable<ClusterNode> nodes,
    {required String hcloudToken, required String sshKeyName}) async {
  final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
  echo('************* DESTROYING NODES *************');
  //
  // 1. Find existing nodes by checking hcloud server list
  final existingNodes = (await hcloud.getServers()).toList();

  final destroying = nodes.map((node) {
    if (existingNodes.any((n) => n.name == node.name)) {
      echo('Node ${node.name} exists, destroying...');
      return hcloud.destroyServer(node.id);
    } else {
      echo('Node ${node.name} does not exist, skipping...');
      return Future.value();
    }
  });
  await Future.wait(destroying);
}

Future<void> installNixos(Directory workingDir, Iterable<ClusterNode> nodes,
    {required String nixVersion,
    required String sshKeyName,
    bool debug = false}) async {
  final progressBar = AsciiProgressBar();

  final installNixos = nodes.map((node) async {
    final progressBarId = <String, int?>{"current": null};
    final nixChannel = 'nixos-$nixVersion';
    final installScript = """#!/usr/bin/env bash
echo "mute=on"
curl -s https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | NO_REBOOT=true NIX_CHANNEL=$nixChannel bash -x 2>/dev/null;

# Make sure we use custom configuration on reboot
cp -f /root/configuration.nix /etc/nixos/configuration.nix;

# Some picks from the nixos-infect script
/nix/var/nix/profiles/system/sw/bin/nix-collect-garbage 2>/dev/null;
/nix/var/nix/profiles/system/bin/switch-to-configuration boot 2>/dev/null;
reboot;
    """;
// begore GC:
// NIXOS_CONFIG=/etc/nixos/configuration.nix nix-env --set -I nixpkgs=\$(realpath \$HOME/.nix-defexpr/channels/nixos) -f '<nixpkgs/nixos>' -p /nix/var/nix/profiles/system -A system;

    final authorizedKey =
        await getSshKeyAsPem(workingDir, '${node.sshKeyName}.pub');

    final SSHSocket connection = await waitAndGetSshConnection(node);
    final SSHClient sshClient =
        await getSshClient(workingDir, node, connection);

    // await sshClient.run('mkdir -p /etc/nixos');

    final sftp = await sshClient.sftp();

    await sftpWrite(sftp, installScript, '/root/install.sh');
    await sftpSend(
        sftp, '${workingDir.path}/configuration.nix', '/root/configuration.nix',
        substitutions: {
          'sshKey': authorizedKey,
          'nixVersion': nixVersion,
          'nodeName': node.name,
        });

    sftp.close();
    sshClient.close();

    try {
      bool mute = false;
      final controller = StreamController<List<int>>();
      controller.stream.listen((inp) {
        final str = utf8.decode(inp);
        // stdout.write('+');
        // return;

        if (str.contains('mute=on')) {
          mute = true;
        } else if (str.contains('mute=off')) {
          mute = false;
        }

        if (mute) {
          if (str.contains('bin/nix-collect-garbage')) {
            // + /nix/var/nix/profiles/system/sw/bin/nix-collect-garbage
            progressBarId['current'] =
                progressBar.update(progressBarId['current'], 'GC');
          } else if (str == "renamed '/boot' -> '/boot.bak'") {
            // mv -v /boot /boot.bak
            progressBarId['current'] =
                progressBar.update(progressBarId['current'], '@');
          } else {
            // stdout.write('+');
            progressBarId['current'] =
                progressBar.update(progressBarId['current'], '+');
          }
        } else {
          stdout.write(str);
        }
      }, onError: (inp) {
        final str = utf8.decode(inp);
        if (str.contains('closed by remote host')) {
          // This is fine, happens on reboot
          progressBarId['current'] =
              progressBar.update(progressBarId['current'], '!');
        } else {
          stderr.write(str);
        }
        stderr.write(str);
      }, onDone: () {
        progressBarId['current'] =
            progressBar.update(progressBarId['current'], '!');
      });
      final shell = Shell(stdout: controller.sink, verbose: debug);
      // Probably better to do this outside for all commands
      // await shell.run('ssh-add "${workingDir.path}/ssh/$sshKeyName"');
      await shell.run(
          // 'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "reboot 2>/dev/null"');
          'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "bash -s " < /root/install.sh');
      // Running in two part to allow nix-env to be provided by the profile script
    } on ShellException catch (_) {
      // We will get a shell exception when connection terminates
    } catch (err) {
      if (debug) echoDebug(err.toString());
    }

    // TODO: Mark done?
    // stdout.write(node.name);
  });

  await Future.wait(installNixos);

  await Future.delayed(const Duration(seconds: 5));

  await waitForSsh(nodes);

  final rebuildWaiters = nodes.map((node) async {
    try {
      final controller = StreamController<List<int>>();
      final shell = Shell(stdout: controller.sink);
      await shell.run(
          'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "nixos-rebuild switch --fast 2>/dev/null"');
    } catch (_) {}
  });

  await Future.wait(rebuildWaiters);
}

Future<void> rebootToNixos(Directory workingDir,
    ClusterConfiguration clusterConf, Iterable<ClusterNode> nodes) async {
  final bootToNixos = nodes.map((node) async {
    // debug(node.name);
    final script =
        'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "reboot 2>/dev/null"';

    final controller = StreamController<List<int>>();
    controller.stream.listen((inp) {
      final str = utf8.decode(inp);
      stdout.write(str);
    }, onError: (inp) {
      // final str = utf8.decode(inp);
      // stderr.write(str);
      stderr.write('-');
    }, onDone: () {
      stdout.write('!');
    });

    final shell = Shell(stdout: controller.sink);
    try {
      await shell.run("""
          $script
        """);
    } on ShellException catch (_) {
      // We will get a shell exception
    }
  });

  await Future.wait(bootToNixos);
}

Future<void> waitForServers(Directory workingDir, Iterable<ClusterNode> nodes,
    {required String hcloudToken, required String sshKeyName}) async {
  final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
  final waitForAll = nodes.map((node) async {
    var maxTries = 100;
    while (maxTries-- > 0) {
      final action = await hcloud.getServerAction(node, 'start_server');
      if (action['progress'] >= 100) return Future.value();

      await Future.delayed(const Duration(seconds: 2));
    }
  });

  await Future.wait(waitForAll);
}

Future<void> rebuildNixos(Directory workingDir,
    ClusterConfiguration clusterConf, Iterable<ClusterNode> nodes) async {
  final rebuild = nodes.map((node) async {
    // debug(node.name);
    final script =
        'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "nixos-rebuild switch --fast"'; // 2>/dev/null
    // For debugging: nixos-rebuild switch --fast  --show-trace --option eval-cache false

    final controller = StreamController<List<int>>();
    controller.stream.listen((inp) {
      final str = utf8.decode(inp);
      stdout.write(str);
    }, onError: (inp) {
      final str = utf8.decode(inp);
      stderr.write(str);
      // stderr.write('-');
    }, onDone: () {
      stdout.write('!');
    });

    final shell = Shell(stdout: controller.sink);
    try {
      await shell.run("""
          $script
        """);
    } on ShellException catch (_) {
      // We will get a shell exception
    }
  });

  await Future.wait(rebuild);
}

// Convert this to update nodes
Future<void> nixosRebuild(
    Directory workingDir, Iterable<ClusterNode> nodes) async {
  final rebuilders = nodes.map((node) async {
    final sshClient = SSHClient(
      await SSHSocket.connect(node.ipAddr, 22),
      username: 'root',
      identities: [
        ...SSHKeyPair.fromPem(await getSshKeyAsPem(workingDir, node.sshKeyName))
      ],
    );

    await sshClient.run('nixos-rebuild switch --fast');
    sshClient.close();
  });

  await Future.wait(rebuilders);
}
