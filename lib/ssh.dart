import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:process_run/shell.dart';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:dartssh2/dartssh2.dart';

final sshTimeoutDuration = Duration(milliseconds: 1000);

/// Hint appended to SSH connection errors for nodes that require a VPN
/// connection (the `vpn` field in servers.yaml). Lets a consuming agent
/// know it should ask the user to start the VPN and retry.
String vpnRequiredHint(ClusterNode node) => node.requiresVpn
    ? '\nNOTE: This node requires the VPN connection "${node.vpn}" to be '
        'active on this machine. If the server is unreachable, ask the user '
        'to start the VPN connection and retry.'
    : '';

/// The text of a failed SSH authentication to [node].
///
/// When the node uses the key of SSH_KEY_PATH ([ClusterNode.sshKeyPathFromEnv]),
/// there is no other key to try: the machine does not accept that key.
/// Otherwise the text is the one nix-infra always gave.
String sshAuthenticationFailedMessage(ClusterNode node) {
  final where =
      'Failed to authenticate to server "${node.name}" at ${node.ipAddr}:22\n';
  if (node.sshKeyPathFromEnv) {
    return '${where}Reason: the machine does not accept the key of '
        'SSH_KEY_PATH. It may belong to another SSH key (in sysops: open a '
        'terminal with the key of this machine).';
  }
  return '${where}Reason: SSH authentication failed - check SSH key '
      'permissions and configuration';
}

/// Closes [sftp] and waits until the server has closed its channel.
///
/// An error of the close is ignored: the work on the channel is done, and in
/// a `catch` or `finally` the close must not hide the error being handled.
Future<void> closeSftpQuietly(SftpClient? sftp) async {
  if (sftp == null) return;
  try {
    await sftp.close();
  } catch (_) {
    // Ignored, see above.
  }
}

/// Closes [sftp] (when given) and then [sshClient], and waits for both.
///
/// An error of a close is ignored, as in [closeSftpQuietly]. Since dartssh2
/// 3.0 `SSHClient.close()` and `SftpClient.close()` return a `Future`; every
/// connection of nix-infra is closed through this function or
/// [closeSftpQuietly], so the closes are awaited and done in this order.
Future<void> closeSshQuietly(SSHClient? sshClient, {SftpClient? sftp}) async {
  await closeSftpQuietly(sftp);
  if (sshClient == null) return;
  try {
    await sshClient.close();
  } catch (_) {
    // Ignored, see above.
  }
}

Future<String> runCommandOverSsh(
    Directory workingDir, ClusterNode node, String cmd,
    {Duration? connectTimeout}) async {
  SSHSocket? socket;
  SSHClient? sshClient;

  try {
    socket =
        await SSHSocket.connect(node.ipAddr, 22, timeout: connectTimeout);

    sshClient = SSHClient(
      socket,
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
    await closeSshQuietly(sshClient);
    return utf8.decode(res);
  } catch (e) {
    socket?.destroy();
    await closeSshQuietly(sshClient);

    final errorMsg = e.toString();
    if (errorMsg.contains('Connection refused')) {
      throw Exception(
          'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n'
          'Reason: Connection refused - SSH service may not be running or firewall is blocking port 22'
          '${vpnRequiredHint(node)}');
    } else if (errorMsg.contains('timed out') || errorMsg.contains('timeout')) {
      throw Exception(
          'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n'
          'Reason: Connection timeout - server may be unreachable or offline'
          '${vpnRequiredHint(node)}');
    } else if (errorMsg.contains('Authentication failed') ||
        errorMsg.contains('auth')) {
      throw Exception(sshAuthenticationFailedMessage(node));
    } else {
      throw Exception(
          'Failed to execute command on server "${node.name}" at ${node.ipAddr}:22\n'
          'Reason: $errorMsg${vpnRequiredHint(node)}');
    }
  }
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

  final ServerSocket serverSocket;
  try {
    serverSocket = await ServerSocket.bind('127.0.0.1', localPort);
  } catch (_) {
    await closeSshQuietly(sshClient);
    rethrow;
  }

  // Ctrl-C (or SIGTERM) stops the command: close the local server socket, so
  // that the forward ends and its SSH client is closed.
  final signalSubscriptions = [
    ProcessSignal.sigint.watch().listen((_) => serverSocket.close()),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((_) => serverSocket.close()),
  ];
  try {
    await forwardLocalPort(sshClient, serverSocket, overlayIp, remotePort);
  } finally {
    for (final subscription in signalSubscriptions) {
      await subscription.cancel();
    }
  }
}

/// Forwards each connection to [serverSocket] through [sshClient] to
/// [remoteHost]:[remotePort] until the forward ends: [serverSocket] is closed,
/// the SSH connection ends, or a channel cannot be opened (that error is
/// rethrown, as before).
///
/// When the forward ends, the open connections are ended, and [serverSocket]
/// and [sshClient] are closed.
Future<void> forwardLocalPort(SSHClient sshClient, ServerSocket serverSocket,
    String remoteHost, int remotePort) async {
  final connections = <Socket>{};

  // The SSH connection ends (the machine closes it, or the network fails):
  // stop accepting connections.
  unawaited(sshClient.done
      .then((_) {}, onError: (_) {})
      .whenComplete(() => serverSocket.close()));

  try {
    await for (final socket in serverSocket) {
      final SSHForwardChannel forward;
      try {
        forward = await sshClient.forwardLocal(remoteHost, remotePort);
      } catch (_) {
        socket.destroy();
        rethrow;
      }
      connections.add(socket);
      unawaited(socket.done
          .then((_) {}, onError: (_) {})
          .whenComplete(() => connections.remove(socket)));
      forward.stream.cast<List<int>>().pipe(socket);
      socket.cast<List<int>>().pipe(forward.sink);
    }
  } finally {
    await serverSocket.close();
    for (final socket in connections.toList()) {
      socket.destroy();
    }
    await closeSshQuietly(sshClient);
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

  await closeSshQuietly(sshClient, sftp: sftp);
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
    //         timeout: sshTimeoutDuration,),
    //   username: 'root',
    //   identities: [
    //     ...SSHKeyPair.fromPem(await getSshKeyAsPemFromNode(workingDir, node))
    //   ],
    // );
    var maxTries = 20;
    while (maxTries-- > 0) {
      try {
        final socket = await SSHSocket.connect(
          node.ipAddr,
          22,
          timeout: sshTimeoutDuration,
        );
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
    {int maxTries = 20, Duration? totalBudget}) async {
  Exception? lastError;

  if (totalBudget != null) {
    // Each attempt takes up to ~1.5s (1s connect timeout + 500ms delay).
    final tries = (totalBudget.inMilliseconds / 1500).floor();
    maxTries = tries > 0 ? tries : 1;
  }

  while (maxTries-- > 0) {
    try {
      final socket = await SSHSocket.connect(
        node.ipAddr,
        22,
        timeout: sshTimeoutDuration,
      );
      print(''); // Add a newline
      return socket;
    } catch (e) {
      lastError = e is Exception ? e : Exception(e.toString());
      stdout.write(':');
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  // Provide detailed error message
  final errorDetails = lastError?.toString() ?? 'Unknown error';
  String errorMsg =
      'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n';

  if (errorDetails.contains('Connection refused')) {
    errorMsg +=
        'Reason: Connection refused - SSH service may not be running or firewall is blocking port 22';
  } else if (errorDetails.contains('timed out') ||
      errorDetails.contains('timeout')) {
    errorMsg +=
        'Reason: Connection timeout - server may be unreachable or offline';
  } else if (errorDetails.contains('No route to host')) {
    errorMsg +=
        'Reason: No route to host - check network configuration and IP address';
  } else if (errorDetails.contains('Network is unreachable')) {
    errorMsg += 'Reason: Network unreachable - check your network connection';
  } else {
    errorMsg += 'Reason: $errorDetails';
  }

  throw Exception(errorMsg + vpnRequiredHint(node));
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
  SSHSocket? socket;
  SSHClient? sshClient;
  SSHSession? shell;

  try {
    socket = await SSHSocket.connect(node.ipAddr, 22);

    sshClient = SSHClient(
      socket,
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

    shell = await sshClient.shell(
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
      shell!.write(uint8Data);
    });

    await shell.done;

    stdin.echoMode = true;
    stdin.lineMode = true;

    shell.close();
    await closeSshQuietly(sshClient);
  } catch (e) {
    // Restore terminal settings on error
    stdin.echoMode = true;
    stdin.lineMode = true;

    shell?.close();
    await closeSshQuietly(sshClient);
    socket?.destroy();

    final errorMsg = e.toString();
    if (errorMsg.contains('Connection refused')) {
      throw Exception(
          'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n'
          'Reason: Connection refused - SSH service may not be running or firewall is blocking port 22');
    } else if (errorMsg.contains('timed out') || errorMsg.contains('timeout')) {
      throw Exception(
          'Failed to connect to server "${node.name}" at ${node.ipAddr}:22\n'
          'Reason: Connection timeout - server may be unreachable or offline');
    } else if (errorMsg.contains('Authentication failed') ||
        errorMsg.contains('auth')) {
      throw Exception(sshAuthenticationFailedMessage(node));
    } else {
      throw Exception(
          'Failed to open SSH shell to server "${node.name}" at ${node.ipAddr}:22\n'
          'Reason: $errorMsg');
    }
  }
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
