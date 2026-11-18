// A login with a key file of the project against a local `sshd`, with
// dartssh2 4.1 (docs/design/ssh_agent_keys.md §10, "Also with a key file, to
// cover the upgrade"). The key files are made as `nix-infra init` makes
// them; `sshd` runs as the current user on 127.0.0.1 and a free port.
//
// Skipped when `ssh-keygen` or `sshd` cannot be found.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'support/ssh_test_env.dart';

const _timeout = Duration(seconds: 10);

void main() {
  group('a key file against a local sshd', () {
    late SshdKeyFileTestEnv env;

    setUpAll(() async {
      // `other-key` exists in ssh/ but the machine does not accept it.
      env = await SshdKeyFileTestEnv.start(
        keys: ['test-key', 'other-key'],
        authorized: ['test-key'],
      );
    });

    tearDownAll(() async => env.stop());

    /// A machine on 127.0.0.1 that uses `ssh/<keyName>` of the project, or
    /// the key file [sshKeyPath] (`ssh_key` of servers.yaml).
    ClusterNode machine(String keyName, {String? sshKeyPath}) =>
        ClusterNode('local', '127.0.0.1', 1, keyName, sshKeyPath: sshKeyPath)
          ..username = env.user;

    Future<SSHClient> connect(ClusterNode node) async {
      final socket =
          await SSHSocket.connect('127.0.0.1', env.port, timeout: _timeout);
      return getSshClient(env.dir, node, socket, timeout: _timeout);
    }

    test('runCommandOverSsh runs a command with ssh/<SSH_KEY>', () async {
      final output = await runCommandOverSsh(
          env.dir, machine('test-key'), 'echo ok',
          port: env.port, connectTimeout: _timeout);
      expect(output.trim(), 'ok');
    });

    test('runCommandOverSsh runs a command with ssh_key of servers.yaml',
        () async {
      final output = await runCommandOverSsh(
          env.dir, machine('no-such-key', sshKeyPath: './ssh/test-key'),
          'echo ok',
          port: env.port, connectTimeout: _timeout);
      expect(output.trim(), 'ok');
    });

    test('an SFTP upload with sftpMkDirRecursive and sftpSend', () async {
      final local = File(path.join(env.dir.path, 'hello.txt'))
        ..writeAsStringSync('hello over sftp\n');
      final remoteDir = path.join(env.dir.path, 'uploads', 'nested');

      final sshClient = await connect(machine('test-key'));
      SftpClient? sftp;
      try {
        sftp = await sshClient.sftp();
        await sftpMkDirRecursive(sftp, remoteDir);
        await sftpSend(sftp, local.path, '$remoteDir/hello.txt');
      } finally {
        await closeSshQuietly(sshClient, sftp: sftp)
            .timeout(_timeout, onTimeout: () => fail('the close hangs'));
      }

      expect(sshClient.isClosed, isTrue);
      expect(File(path.join(remoteDir, 'hello.txt')).readAsStringSync(),
          'hello over sftp\n');
    });

    test('a key that the machine does not accept: authentication failed',
        () async {
      final node = machine('other-key');
      await expectLater(
          runCommandOverSsh(env.dir, node, 'echo ok',
              port: env.port, connectTimeout: _timeout),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              'Exception: ${sshAuthenticationFailedMessage(node)}')));
    });

    test('a closed port: connection refused', () async {
      final closedPort = await freeLocalPort();
      await expectLater(
          runCommandOverSsh(env.dir, machine('test-key'), 'echo ok',
              port: closedPort, connectTimeout: _timeout),
          throwsA(isA<Exception>().having(
              (e) => e.toString(),
              'toString()',
              'Exception: Failed to connect to server "local" at '
                  '127.0.0.1:22\n'
                  'Reason: Connection refused - SSH service may not be '
                  'running or firewall is blocking port 22')));
    });

    test('a server that never finishes the handshake: the timeout text',
        () async {
      // Accepts the connection and never sends a byte.
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      silent.listen(accepted.add);
      try {
        final started = DateTime.now();
        await expectLater(
            runCommandOverSsh(env.dir, machine('test-key'), 'echo ok',
                port: silent.port,
                connectTimeout: const Duration(seconds: 1)),
            throwsA(isA<Exception>().having(
                (e) => e.toString(),
                'toString()',
                'Exception: Failed to connect to server "local" at '
                    '127.0.0.1:22\n'
                    'Reason: Connection timeout - server may be unreachable '
                    'or offline')));
        expect(DateTime.now().difference(started), lessThan(_timeout));
      } finally {
        for (final socket in accepted) {
          socket.destroy();
        }
        await silent.close();
      }
    });

    test('forwardLocalPort forwards, and closes its client at the end',
        () async {
      // The far end of the forward: an echo server.
      final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echo.listen((socket) => socket.listen(socket.add,
          onDone: () => socket.close(), onError: (_) => socket.destroy()));
      final local = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sshClient = await connect(machine('test-key'));
      Socket? client;
      try {
        final forward =
            forwardLocalPort(sshClient, local, '127.0.0.1', echo.port);

        client = await Socket.connect('127.0.0.1', local.port);
        final reply = utf8.decoder.bind(client).first;
        client.add(utf8.encode('ping'));
        expect(await reply.timeout(_timeout), 'ping');

        // The forward ends when its server socket closes.
        await local.close();
        await forward.timeout(_timeout);
        expect(sshClient.isClosed, isTrue);
      } finally {
        client?.destroy();
        await local.close();
        await echo.close();
        await closeSshQuietly(sshClient);
      }
    });
  }, skip: sshTestEnvSkip(SshdKeyFileTestEnv.tools));
}
