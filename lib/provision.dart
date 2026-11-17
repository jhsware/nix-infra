import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';

import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/ssh_key_path.dart';
import 'package:nix_infra/types.dart';
import 'package:process_run/shell.dart';

/// Create nodes using the provided infrastructure provider.
///
/// This function requires a provider that supports server creation.
/// For HetznerCloud, it also supports placement groups.
Future<List<String>> createNodes(
  Directory workingDir,
  List<String> nodeNames, {
  required InfrastructureProvider provider,
  required String location,
  required String sshKeyName,
  required String machineType,
  String? placementGroup,
}) async {
  if (provider.supportsAddSshKey) {
    await provider.addSshKeyToCloudProvider(workingDir, sshKeyName);
  }

  int? placementGroupId;
  if (placementGroup != null && provider.supportsPlacementGroups) {
    // Placement groups are HetznerCloud-specific
    if (provider is HetznerCloud) {
      final placementGroups = await provider.getPlacementGroups();
      if (placementGroups.any((el) => el.name == placementGroup)) {
        final group =
            placementGroups.firstWhere((el) => el.name == placementGroup);
        placementGroupId = group.id;
      } else {
        final group = await provider.createPlacementGroup(placementGroup);
        placementGroupId = group.id;
      }
    }
  }

  echo('************* SPAWNING NODES *************');
  //
  // 1. Find existing nodes by checking server list
  final existingNodes = (await provider.getServers()).toList();
  final createdNodes = <String>[];

  for (final name in nodeNames) {
    if (existingNodes.any((node) => node.name == name)) {
      echo('Node $name already exists, skipping!');
      continue;
    } else {
      echo("Node: $name doesn't exist, creating...");
      await provider.createServer(
        name,
        machineType,
        location,
        sshKeyName,
        placementGroupId,
      );
      createdNodes.add(name);
    }
  }
  return createdNodes;
}

/// Destroy nodes using the provided infrastructure provider.
///
/// This function requires a provider that supports server destruction.
Future<void> destroyNodes(
  Directory workingDir,
  Iterable<ClusterNode> nodes, {
  required InfrastructureProvider provider,
}) async {
  if (!provider.supportsDestroyServer) {
    throw UnsupportedError(
      '${provider.providerName} does not support destroying servers. '
      'For self-hosted servers, remove them manually from servers.yaml instead.',
    );
  }

  echo('************* DESTROYING NODES *************');
  //
  // 1. Find existing nodes by checking server list
  final existingNodes = (await provider.getServers()).toList();

  final destroying = nodes.map((node) {
    if (existingNodes.any((n) => n.name == node.name)) {
      echo('Node ${node.name} exists, destroying...');
      return provider.destroyServer(node.id);
    } else {
      echo('Node ${node.name} does not exist, skipping...');
      return Future.value();
    }
  });
  await Future.wait(destroying);
}

Future<void> installNixos(
  Directory workingDir,
  Iterable<ClusterNode> nodes, {
  required String nixVersion,
  required String sshKeyName,
  String? mutation,
  InfrastructureProvider? provider,
  bool debug = true,
}) async {
  final progressBar = AsciiProgressBar();

  final nixChannel = 'nixos-$nixVersion';
  final muteUnlessDebug = debug ? "" : "2>/dev/null";
  final rebootCommand = debug
      ? "echo 'When --debug is set you are required to reboot the server manually.'"
      : "reboot";

  // nixos-infect no longer autodetects the provider (upstream elitak#226),
  // so we set PROVIDER explicitly, per node. servers.yaml is the source of
  // truth: a node with `provider: hetzner` gets PROVIDER=hetznercloud, a
  // static self-hosted node gets none. Nodes without cloud provider info
  // (external callers) default to hetznercloud unless they come from the
  // self-hosting provider. On Hetzner this enables doNetConf=y, which
  // generates the networking.nix that our configuration.nix imports.
  String infectEnv(ClusterNode node) {
    if (node.cloudProvider == 'hetzner') return 'PROVIDER=hetznercloud ';
    if (node.cloudProvider == null &&
        (provider == null || provider is HetznerCloud)) {
      return 'PROVIDER=hetznercloud ';
    }
    return '';
  }

  String makeInstallScript(ClusterNode node) {
    final infectProvider = infectEnv(node);
    final installCommand = mutation != null
        ? "curl -fsS https://raw.githubusercontent.com/jhsware/nixos-infect/refs/heads/ki-dev/mutations/$mutation | ${infectProvider}NO_DAEMON=true NIX_CHANNEL=$nixChannel bash -s -- --apply $muteUnlessDebug"
        : "curl -fsS https://raw.githubusercontent.com/jhsware/nixos-infect/refs/heads/master/nixos-infect | ${infectProvider}NO_DAEMON=true NO_REBOOT=true NIX_CHANNEL=$nixChannel bash -x $muteUnlessDebug";

    // The script stops before the reboot when a step fails. A failed node is
    // not rebooted and stays reachable over SSH. Sentinels in the output:
    //   NIX_INFRA_FACT <node>: boot facts (EFI/BIOS, disks, efibootmgr)
    //   NIX_INFRA_FAIL <node>: a step failed, the node was not rebooted
    //   NIX_INFRA_OK <node>:   all checks passed, reboot follows
    return """#!/usr/bin/env bash
set -euo pipefail

# Node boot facts, printed before muting so they are always visible
if [ -d /sys/firmware/efi ]; then echo "NIX_INFRA_FACT ${node.name}: boot_mode=EFI"; else echo "NIX_INFRA_FACT ${node.name}: boot_mode=BIOS"; fi
echo "NIX_INFRA_FACT ${node.name}: disks=\$(lsblk -dno NAME,SIZE,TYPE 2>/dev/null | tr '\\n' ' ')"
if [ -d /sys/firmware/efi ] && command -v efibootmgr >/dev/null 2>&1; then
  efibootmgr 2>/dev/null | sed "s/^/NIX_INFRA_FACT ${node.name}: efi /" || true
fi

echo "mute=on"
$installCommand || { echo "NIX_INFRA_FAIL ${node.name}: nixos-infect exited with an error"; exit 1; }

# Make sure we use custom configuration on reboot
cp -f /root/configuration.nix /etc/nixos/configuration.nix || { echo "NIX_INFRA_FAIL ${node.name}: could not install configuration.nix"; exit 1; }

test -x /nix/var/nix/profiles/system/bin/switch-to-configuration || { echo "NIX_INFRA_FAIL ${node.name}: no NixOS system profile"; exit 1; }

# Some picks from the nixos-infect script
/nix/var/nix/profiles/system/sw/bin/nix-collect-garbage 2>/dev/null || true
# NIXOS_INSTALL_BOOTLOADER=1 forces a full bootloader install on every run.
# A retried install wipes the ESP, and without this flag install-grub skips
# grub-install because its state file is unchanged, which leaves the ESP
# without an EFI boot file.
NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot || { echo "NIX_INFRA_FAIL ${node.name}: bootloader install failed"; exit 1; }

if [ -f /boot/grub/grub.cfg ]; then
  grep -q NixOS /boot/grub/grub.cfg || { echo "NIX_INFRA_FAIL ${node.name}: no NixOS entry in /boot/grub/grub.cfg"; exit 1; }
else
  echo "NIX_INFRA_FACT ${node.name}: no /boot/grub/grub.cfg, menu check skipped"
fi

if [ -d /sys/firmware/efi ]; then
  find /boot -maxdepth 4 -ipath '*/efi/boot/boot*.efi' 2>/dev/null | grep -q . || { echo "NIX_INFRA_FAIL ${node.name}: no EFI boot file found under /boot"; exit 1; }
fi

echo "NIX_INFRA_OK ${node.name}"
# Give the sentinel time to flush over SSH before the connection drops
sleep 2
$rebootCommand
""";
  }

  final failedNodes = <String>{};

  final installNixos = nodes.map((node) async {
    final progressBarId = <String, int?>{"current": null};
    final nodeOutput = StringBuffer();
// begore GC:
// NIXOS_CONFIG=/etc/nixos/configuration.nix nix-env --set -I nixpkgs=\$(realpath \$HOME/.nix-defexpr/channels/nixos) -f '<nixpkgs/nixos>' -p /nix/var/nix/profiles/system -A system;

    final installScript = makeInstallScript(node);
    final authorizedKey = await publicKeyOf(workingDir, node);

    final SSHSocket connection = await waitAndGetSshConnection(node);
    final SSHClient sshClient =
        await getSshClient(workingDir, node, connection);

    // await sshClient.run('mkdir -p /etc/nixos');

    final sftp = await sshClient.sftp();

    await sftpWrite(sftp, installScript, '/root/install.sh');

    await sftpSend(
        sftp, '${workingDir.path}/configuration.nix', '/root/configuration.nix',
        substitutions: {
          'nixVersion': nixVersion,
          'nodeName': node.name,
          'sshKey': authorizedKey,
        });

    sftp.close();
    sshClient.close();

    try {
      bool mute = false;
      final controller = StreamController<List<int>>();
      controller.stream.listen((inp) {
        final str = utf8.decode(inp);
        nodeOutput.write(str);
        // stdout.write('+');
        // return;

        if (str.contains('mute=on')) {
          mute = true;
        } else if (str.contains('mute=off')) {
          mute = false;
        }

        if (!debug && mute) {
          if (str.contains('NIX_INFRA_')) {
            // Sentinels and boot facts are always shown
            stdout.write('\n$str');
          } else if (str.contains('bin/nix-collect-garbage')) {
            // + /nix/var/nix/profiles/system/sw/bin/nix-collect-garbage
            progressBarId['current'] =
                progressBar.update(progressBarId['current'], 'GC');
          } else if (str.contains("renamed '/boot")) {
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
          'ssh -i "${node.getEffectiveSshKeyPath(workingDir.path)}" -o StrictHostKeyChecking=no root@${node.ipAddr} "bash -s " < /root/install.sh');
      // Running in two part to allow nix-env to be provided by the profile script
    } on ShellException catch (_) {
      // We will get a shell exception when connection terminates
    } catch (err) {
      if (debug) echoDebug(err.toString());
    }

    final out = nodeOutput.toString();
    if (out.contains('NIX_INFRA_FAIL') || !out.contains('NIX_INFRA_OK')) {
      failedNodes.add(node.name);
      echo('ERROR! Install did not complete on ${node.name}. '
          'The node was not rebooted and is still reachable over SSH. '
          'Look for NIX_INFRA_FAIL in the output above.');
    }
  });

  await Future.wait(installNixos);

  final okNodes =
      nodes.where((node) => !failedNodes.contains(node.name)).toList();
  if (failedNodes.isNotEmpty) {
    echo('WARN! Install failed on: ${failedNodes.join(', ')}. '
        'These nodes were not rebooted and are still reachable over SSH.');
  }
  if (okNodes.isEmpty) return;

  await Future.delayed(const Duration(seconds: 5));

  await waitForSsh(okNodes);

  final rebuildWaiters = okNodes.map((node) async {
    try {
      final controller = StreamController<List<int>>();
      final shell = Shell(stdout: controller.sink);
      await shell.run(
          'ssh -i "${node.getEffectiveSshKeyPath(workingDir.path)}" -o StrictHostKeyChecking=no root@${node.ipAddr} "nixos-rebuild switch --fast 2>/dev/null"');
    } catch (_) {}
  });

  await Future.wait(rebuildWaiters);
}

Future<void> rebootToNixos(Directory workingDir,
    ClusterConfiguration clusterConf, Iterable<ClusterNode> nodes) async {
  final bootToNixos = nodes.map((node) async {
    // debug(node.name);
    final script =
        'ssh -i "${node.getEffectiveSshKeyPath(workingDir.path)}" -o StrictHostKeyChecking=no root@${node.ipAddr} "reboot 2>/dev/null"';

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

/// Wait for servers to be ready after creation.
///
/// This is a HetznerCloud-specific operation that polls the server action status.
/// For other providers, this function does nothing (assumes servers are ready).
Future<void> waitForServers(
  Directory workingDir,
  Iterable<ClusterNode> nodes, {
  required InfrastructureProvider provider,
}) async {
  // Server action polling is HetznerCloud-specific
  if (provider is! HetznerCloud) {
    // For other providers, just wait for SSH to be available
    return;
  }

  final hcloud = provider;
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
        'ssh -i "${node.getEffectiveSshKeyPath(workingDir.path)}" -o StrictHostKeyChecking=no root@${node.ipAddr} "nixos-rebuild switch --fast"'; // 2>/dev/null
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
    final output = await runCommandOverSsh(
        workingDir, node, 'nixos-rebuild switch --fast --impure');
    echoFromNode(node.name, output);
  });

  await Future.wait(rebuilders);
}

