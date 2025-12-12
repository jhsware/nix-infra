import 'dart:async';
import 'dart:convert';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:process_run/shell.dart';
// systemd-creds encrypt - /root/secrets/[app-name].enc <<<"secret goes here"

// 1. Make sure "/root/secrets" exists
// 2. Make sure "ca/secrets" exists
// 3. Create a new secret file with "systemd-creds encrypt - /root/secrets/[secret-namespaced].enc <<<"secret"
// - store the secret encrypted in "ca/secrets", encrypted with systemd-creds encrypt
// - use that secret to

// Encrypt stdin to a file
// openssl enc -pbkdf2 -pass pass:thisisatest1 -a -out test3.enc <<<"secret"
// Decrypt file to stdout
// openssl enc -pbkdf2 -pass pass:thisisatest1 -d -in test3.enc -a -d

/*
1. Make sure we have [cluster_root]/secrets
2. Generate a secret and encrypt it in [cluster_root]/secrets/[secret.namespace].enc
3. When deploying apps on node, figure out what secrets are needed and deploy them in /root/secrets 400, clear those not needed
4. 

use action command to create secrets

*/
import 'dart:io';

Future<void> saveSecret(Directory workingDir, String secretsPassword,
    String secretNamespace, String secret,
    {bool debug = false}) async {
  final secretsDir = Directory('${workingDir.path}/secrets');

  if (!secretsDir.existsSync()) {
    echo('Create secrets dir');
    final shell = Shell(
      runInShell: true,
      verbose: debug,
    );
    mkdir(secretsDir.path);
    await shell.run('chmod 700 ${secretsDir.path}');
  }

  final controller = StreamController<List<int>>();

  final shell1 = Shell(
    environment: {
      'SECRETS_PASS': secretsPassword,
    },
    runInShell: true,
    verbose: debug,
    stdin: controller.stream,
  );

  controller.add(utf8.encode(secret));
  controller.close();
  await shell1.run(
      'openssl enc -pbkdf2 -pass env:SECRETS_PASS -a -out ${secretsDir.path}/$secretNamespace');

  final shell2 = Shell(
    runInShell: true,
    verbose: debug,
  );
  await shell2.run('chmod 400 ${secretsDir.path}/$secretNamespace');
}

Future<String> readSecret(
    Directory workingDir, String secretsPassword, String secretNamespace,
    {bool debug = false}) async {
  final secretsDir = Directory('${workingDir.path}/secrets');
  final secretFile = File('${secretsDir.path}/$secretNamespace');
  if (!secretFile.existsSync()) {
    throw Exception(
        'Secret file "$secretNamespace" not found at "${secretsDir.path}"');
  }

  final shell = Shell(
    environment: {
      'SECRETS_PASS': secretsPassword,
    },
    runInShell: true,
    verbose: debug,
  );

  final res = await shell.run(
      'openssl enc -pbkdf2 -pass env:SECRETS_PASS -d -a -in ${secretsDir.path}/$secretNamespace');

  return res.outText;
}

Future<void> deploySecretOnRemote(
  Directory workingDir,
  String secretName,
  String secret,
  ClusterNode node, {
  required SSHClient sshClient,
  bool debug = false,
}) async {
  final sshCmd =
      'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr}';

  final controller = StreamController<List<int>>();

  final shell = Shell(
    runInShell: true,
    verbose: debug,
    stdin: controller.stream,
  );

  controller.add(utf8.encode(secret));
  controller.close();

  await shell
      .run('$sshCmd "systemd-creds encrypt - /root/secrets/$secretName"');
}

Future<void> syncSecrets(
  Directory workingDir,
  Iterable<ClusterNode> cluster,
  ClusterNode node,
  List<String> expectedSecrets,
  SSHClient sshClient, {
  required String secretsPwd,
  bool debug = false,
  bool overlayNetwork = true,
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

  Map<String, String> nodeSubstitutions = Map.from(substitutions);
  nodeSubstitutions['localhost.hostname'] = node.name;
  nodeSubstitutions['localhost.ipv4'] = node.ipAddr;
  nodeSubstitutions['localhost.overlayIp'] =
      substitutions['${node.name}.overlayIp'] ??
          '-- overlayIp not found in etcd --';

  final sftp = await sshClient.sftp();
  await sftpMkDir(sftp, '/root/secrets');

  if (expectedSecrets.isNotEmpty) {
    if (debug) echoDebug("Deploy secrets on node ${node.name}");
    if (debug) echoDebug('Expected secrets: $expectedSecrets');
    // Deploy secrets to target node
    for (final secretName in expectedSecrets) {
      try {
        final secret = await readSecret(workingDir, secretsPwd, secretName);
        final newSecret =
            substitute(secret, substitutions, expectedSecrets: expectedSecrets);
        await deploySecretOnRemote(
          workingDir,
          secretName,
          newSecret,
          node,
          sshClient: sshClient,
        );
      } catch (err) {
        echo("WARNING! Secret $secretName does not exist in project, skipping");
      }
    }
  }

  final expectedFilenamesOnRemot = ['.', '..'];
  expectedFilenamesOnRemot.addAll(expectedSecrets);

  final listOfFiles = await sftp.listdir('/root/secrets');
  for (final file in listOfFiles) {
    if (!expectedFilenamesOnRemot.contains(file.filename)) {
      echo('/root/secrets/${file.filename}');
      await sftp.remove('/root/secrets/${file.filename}');
    }
  }
  sftp.close();

  // TODO: Garbage collect unused secrets on target node
  // 1. check what secrets exist on remote
  // 2. remove if it not exists in expectedSecrets
}
