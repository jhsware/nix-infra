import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:process_run/shell.dart';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:dartssh2/dartssh2.dart';

Future<String> runCommandOverSsh(
    Directory workingDir, ClusterNode node, String cmd) async {
  final sshClient = SSHClient(
    await SSHSocket.connect(node.ipAddr, 22),
    username: node.username,
    // algorithms: SSHAlgorithms(
    //   kex: const [SSHKexType.x25519],
    //   cipher: const [SSHCipherType.aes256ctr, ],
    //   // mac: const [SSHMacType.hmacSha1],
    // ),
    identities: [
      ...SSHKeyPair.fromPem(await getSshKeyAsPemFromNode(workingDir, node))
    ],
  );

  final res = await sshClient.run(cmd);
  sshClient.close();
  return utf8.decode(res);
}

Future<void> portForward(
  Directory workingDir,
  Iterable<ClusterNode> cluster,
  ClusterNode target,
  int localPort,
  int remotePort, {
  bool overlayNetwork = true,
}) async {
  String? overlayIp;
  if (overlayNetwork) {
    final overlayMeshIps = await getOverlayMeshIps(workingDir, cluster);
    overlayIp = overlayMeshIps[target.name];
  }

  if (overlayIp == null) {
    throw Exception('Target node ${target.name} has no mesh-ip');
  }

  final SSHSocket connection = await waitAndGetSshConnection(target);
  final SSHClient sshClient =
      await getSshClient(workingDir, target, connection);

  final serverSocket = await ServerSocket.bind('127.0.0.1', localPort);
  await for (final socket in serverSocket) {
    final forward = await sshClient.forwardLocal(overlayIp, remotePort);
    forward.stream.cast<List<int>>().pipe(socket);
    socket.cast<List<int>>().pipe(forward.sink);
  }
}

Future<String> runActionScriptOverSsh(
  Directory workingDir,
  Iterable<ClusterNode> cluster, {
  required ClusterNode target,
  required String appModule,
  required String cmd,
  required Iterable<String> envVars,
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
  nodeSubstitutions['localhost.hostname'] = target.name;
  nodeSubstitutions['localhost.ipv4'] = target.ipAddr;
  nodeSubstitutions['localhost.overlayIp'] =
      substitutions['${target.name}.overlayIp'] ??
          '-- overlayIp not found in etcd --';

  final script = File('${workingDir.path}/app_modules/$appModule/action.sh');

  final enviromentVariables =
      envVars.map((envVar) => substitute(envVar, nodeSubstitutions)).join('\n');
  final envVarsToRemote = enviromentVariables.contains('=')
      ? enviromentVariables
          .split('\n')
          .map((e) => '${e.split('=')[0]}="${e.split('=')[1]}"')
          .join(' ')
      : '';
  // final envVarsToRemote = Map.fromEntries(enviromentVariables.split('\n').map((e) => MapEntry(e.split('=')[0], e.split('=')[1])));
  if (debug) {
    echoDebug(jsonEncode(nodeSubstitutions));
    echoDebug("env-vars: $envVarsToRemote");
    echoDebug("Command to run: /root/action.sh $cmd");
  }
  // Don't print this on debug. There is a risk that user passes secrets that are left in the logs
  // print('$envVarsToRemote bash /root/action.sh $cmd');

  final SSHSocket connection = await waitAndGetSshConnection(target);
  final SSHClient sshClient =
      await getSshClient(workingDir, target, connection);
  final sftp = await sshClient.sftp();

  await sftpSend(sftp, script.path, '/root/action.sh');

  echoDebug('$envVarsToRemote bash /root/action.sh $cmd');
  final res = await sshClient.run(
    // '$envVarsToRemote bash -s < /root/action.sh -- $cmd',
    '$envVarsToRemote bash /root/action.sh $cmd',
  );

  // Cleanup
  await sshClient.run('rm /root/action.sh');

  sshClient.close();
  return utf8.decode(res);
}

Future<void> clearKnownHosts(Iterable<ClusterNode> nodes) async {
  final knownHosts = File('${Platform.environment['HOME']}/.ssh/known_hosts');
  final lines = knownHosts.readAsLinesSync();
  final newLines = lines.where((line) {
    return !nodes.any((node) => line.startsWith(node.ipAddr));
  });
  await knownHosts.writeAsString(newLines.join('\n'));
}

Future<void> waitForSsh(Iterable<ClusterNode> nodes) async {
  stdout.write('- ssh: ');
  final sshSessions = nodes.map((node) async {
    // final sshClient = SSHClient(
    //   await SSHSocket.connect(node.ipAddr, 22,
    //         timeout: Duration(milliseconds: 1000)),
    //   username: 'root',
    //   identities: [
    //     ...SSHKeyPair.fromPem(await getSshKeyAsPem(workingDir, node.sshKeyName))
    //   ],
    // );
    var maxTries = 20;
    while (maxTries-- > 0) {
      try {
        final socket = await SSHSocket.connect(node.ipAddr, 22,
            timeout: Duration(milliseconds: 1000));
        socket.destroy();
        stdout.write('!'); // SSH is up
        return;
      } catch (e) {
        stdout.write('.');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  });
  await Future.wait(sshSessions);
  print(''); // Add a newline
}

Future<SSHSocket> waitAndGetSshConnection(ClusterNode node,
    {maxTries = 20}) async {
  while (maxTries-- > 0) {
    try {
      final socket = await SSHSocket.connect(node.ipAddr, 22,
          timeout: Duration(milliseconds: 1000));
      print(''); // Add a newline
      return socket;
    } catch (e) {
      stdout.write(':');
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }
  throw Exception('Could not connect to ${node.ipAddr}');
}

Future<SSHClient> getSshClient(
    Directory workingDir, ClusterNode node, connection) async {
  final nodePemFile = await getSshKeyAsPemFromNode(workingDir, node);
  final sshClient = SSHClient(
    connection,
    username: node.username,
    identities: [...SSHKeyPair.fromPem(nodePemFile)],
  );
  return sshClient;
}

Future<SSHSession> getSshShell(
  SSHClient sshClient, {
  listenToStdOut = false,
  listenToStdErr = false,
}) async {
  final shell = await sshClient.shell();
  if (listenToStdOut) {
    stdout.addStream(shell.stdout);
  }
  if (listenToStdErr) {
    stderr.addStream(shell.stderr);
  }
  return shell;
}

Future<void> openShellOverSsh(Directory workingDir, ClusterNode node) async {
  final sshClient = SSHClient(
    await SSHSocket.connect(node.ipAddr, 22),
    username: node.username,
    // algorithms: SSHAlgorithms(
    //   kex: const [SSHKexType.x25519],
    //   cipher: const [SSHCipherType.aes256ctr, ],
    //   // mac: const [SSHMacType.hmacSha1],
    // ),
    identities: [
      ...SSHKeyPair.fromPem(await getSshKeyAsPemFromNode(workingDir, node))
    ],
  );

  final shell = await sshClient.shell(
      pty: SSHPtyConfig(
          height: stdout.terminalLines,
          width: stdout.terminalColumns,
          type: 'xterm-256color'));
  stdout.addStream(shell.stdout);
  stderr.addStream(shell.stderr);

  stdin.echoMode = false;
  stdin.lineMode = false;

  stdin.listen((List<int> data) {
    final uint8Data = Uint8List.fromList(data);
    shell.write(uint8Data);
  });

  await shell.done;

  stdin.echoMode = true;
  stdin.lineMode = true;

  shell.close();
  sshClient.close();
}

Future<void> createSshKeyPair(
    Directory workingDir, String email, String sshKeyName,
    {bool debug = false, required bool batch}) async {
  final controller = StreamController<List<int>>();
  controller.stream.listen((inp) {
    final str = utf8.decode(inp);
    if (debug) {
      stdout.write(str);
    } else {
      stdout.write('§');
    }
  }, onError: (inp) {
    final str = utf8.decode(inp);
    stderr.write('ERROR: $str');
  }, onDone: () {
    stdout.write('!');
  });

  final shell = Shell(
    environment: {},
    runInShell: true,
    stdout: controller.sink,
    verbose: debug,
  );

  final sshKeysDir = Directory('${workingDir.path}/ssh');
  if (!sshKeysDir.existsSync()) {
    echo('Create ssh dir');
    mkdir(sshKeysDir.path);
    await shell.run('chmod 700 ${sshKeysDir.path}');
  }

  final sshKeyFile = File('${sshKeysDir.path}/$sshKeyName');
  if (!sshKeyFile.existsSync()) {
    echo('Creating SSH key $sshKeyName...');
    await shell.run([
      // 'ssh-keygen -t ed25519 -C $email -f ${sshKeyFile.path} -N ""${debug ? "" : " -q"}');
      'ssh-keygen -t rsa -b 2048',
      '-C $email',
      '-f ${sshKeyFile.path}',
      (batch ? '-N ""' : ''),
      (debug ? '' : '-q'),
    ].join(' '));
    if (debug) echoDebug('Created $sshKeyName ($email)');
  } else {
    echo('SSH key $sshKeyName exists');
  }
}
