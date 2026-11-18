// The agent mode end to end (docs/design/ssh_agent_keys.md §6, §7, §10): a
// machine of servers.yaml, listed with a key map, reached through a real
// ssh-agent by runCommandOverSsh, by an SFTP upload and by `ssh` with the
// command line of sshCommand, against a local sshd. Also the texts of §7
// that need a real login, and that no other key is tried.
//
// Skipped when `ssh-agent`, `ssh-add`, `ssh-keygen` or `sshd` is missing.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/ssh_agent.dart';
import 'package:nix_infra/ssh_identity.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'support/ssh_test_env.dart';

const _timeout = Duration(seconds: 20);

void main() {
  group('the agent mode against a local sshd', () {
    // An agent with an RSA and an Ed25519 key, both authorized by sshd.
    late SshTestEnv env;
    // Another agent with an ECDSA key that sshd does not accept.
    late SshAgentTestEnv otherAgent;
    late Directory project;

    setUpAll(() async {
      env = await SshTestEnv.start(keys: ['rsa', 'ed25519']);
      otherAgent = await SshAgentTestEnv.start(keys: ['ecdsa']);
      project = Directory(path.join(env.dir.path, 'project'))..createSync();
      File(path.join(project.path, 'servers.yaml')).writeAsStringSync('''
servers:
  local:
    ip: 127.0.0.1
    ssh_key: ./ssh/no-such-key
    username: ${env.user}
''');
    });

    tearDownAll(() async {
      await otherAgent.stop();
      await env.stop();
    });

    String fp(String name) => sshKeyFingerprint(env.publicKeyBlob(name));
    String blob(String name) => env.publicKeyLine(name).split(' ')[1];

    /// The lines of the sshd log after [mark] where the client offered a
    /// key or logged in with one (`userauth_pubkey: ...`, `Failed
    /// publickey for ...`, `Accepted publickey for ...`), joined. Not the
    /// lines where sshd (LogLevel DEBUG2) reads `authorized_keys`, which
    /// name every authorized key.
    String offeredKeys(int mark) => env
        .sshdLogLines(from: mark)
        .where((l) => l.contains('userauth_pubkey') || l.contains('publickey for'))
        .join('\n');

    /// Whether [log] names the test key [name].
    bool names(String log, String name) =>
        log.contains(fp(name)) || log.contains(blob(name));

    /// The machine `local` of servers.yaml, listed by SelfHosting with the
    /// key map [map] and the agent socket [socket] (default: [env]).
    Future<ClusterNode> listed(Map<String, dynamic> map,
        {String? socket}) async {
      final mapFile = File(path.join(project.path, 'key_map.json'))
        ..writeAsStringSync(jsonEncode(map));
      final provider = await SelfHosting.load(project,
          sshKeyMapPath: mapFile.path,
          sshAgentSocket: socket ?? env.agentSocket);
      return (await provider.getServers()).single;
    }

    Future<String> echoOk(ClusterNode node) => runCommandOverSsh(
        project, node, 'echo ok',
        port: env.port, connectTimeout: _timeout);

    for (final (name, map) in [
      (
        'ed25519',
        (String fp) => {
              'version': 1,
              'nodes': {
                'local': {'agent_key': fp},
              },
            }
      ),
      (
        'rsa',
        (String fp) => {
              'version': 1,
              'default': {'agent_key': fp},
            }
      ),
    ]) {
      test('$name: runCommandOverSsh runs echo ok with the key of the map',
          () async {
        final node = await listed(map(fp(name)));
        expect(node.keySource, isA<AgentKeySource>());
        final mark = env.sshdLogMark;

        final output = await echoOk(node);

        // sshd (LogLevel DEBUG2) may write debug lines into the output.
        expect(output, contains(RegExp(r'^ok$', multiLine: true)));
        final accepted = await env.waitForSshdLog(
            (l) => l.contains('Accepted publickey'),
            from: mark);
        expect(accepted, contains(fp(name)));
      });
    }

    test('an SFTP upload through the agent', () async {
      final node = await listed({
        'version': 1,
        'default': {'agent_key': fp('rsa')},
      });
      final local = File(path.join(project.path, 'hello.txt'))
        ..writeAsStringSync('hello through the agent\n');
      final remoteDir = path.join(env.dir.path, 'uploads', 'nested');

      final socket =
          await SSHSocket.connect('127.0.0.1', env.port, timeout: _timeout);
      final sshClient =
          await getSshClient(project, node, socket, timeout: _timeout);
      SftpClient? sftp;
      try {
        sftp = await sshClient.sftp();
        await sftpMkDirRecursive(sftp, remoteDir);
        await sftpSend(sftp, local.path, '$remoteDir/hello.txt');
      } finally {
        await closeSshQuietly(sshClient, sftp: sftp);
      }

      expect(File(path.join(remoteDir, 'hello.txt')).readAsStringSync(),
          'hello through the agent\n');
    });

    final ssh = findSshTool('ssh');
    test('ssh with the command line of sshCommand logs in with that key',
        () async {
      final node = await listed({
        'version': 1,
        'default': {'agent_key': fp('ed25519')},
      });
      final mark = env.sshdLogMark;
      String? keyFile;

      final result = await withSshCommand(project, node, (command) {
        keyFile = RegExp(r'-i "([^"]+)"').firstMatch(command)!.group(1);
        // The test user, the port of the test sshd and no ssh config of the
        // developer; the options of nix-infra are kept as they are. A user
        // given with -o before root@<ip> wins over it.
        final testCommand = command.replaceFirst(
            'ssh ',
            '$ssh -F /dev/null -o User=${env.user} -p ${env.port} '
                '-o BatchMode=yes -o UserKnownHostsFile=/dev/null ');
        return Process.run('/bin/sh', ['-c', '$testCommand "echo ok"'],
            environment: {'PATH': Platform.environment['PATH'] ?? ''},
            includeParentEnvironment: false);
      });

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect('${result.stdout}', contains(RegExp(r'^ok$', multiLine: true)));
      expect(File(keyFile!).existsSync(), isFalse,
          reason: 'the public key file is deleted after the command');
      final accepted = await env.waitForSshdLog(
          (l) => l.contains('Accepted publickey'),
          from: mark);
      expect(accepted, contains(fp('ed25519')));
      final offered = offeredKeys(mark);
      expect(names(offered, 'rsa'), isFalse,
          reason: 'only the key of the map is offered:\n$offered');
    }, skip: ssh == null ? 'ssh not on PATH' : false);

    test(
        'a fingerprint that the agent does not hold: the text of §7, and no '
        'key is offered', () async {
      final missing = sshKeyFingerprint(
          Uint8List.fromList(utf8.encode('not a key of the agent')));
      final node = await listed({
        'version': 1,
        'default': {'agent_key': missing},
      });
      final mark = env.sshdLogMark;

      await expectLater(
          echoOk(node),
          throwsA(isA<Exception>().having(
              (e) => e.toString(),
              'toString()',
              'Exception: The SSH agent does not hold the key of machine '
                  '"local" ($missing). If sysops filled the agent: the vault '
                  'may be locked.')));

      // The key is resolved before the connection: sshd saw none.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
          env.sshdLogLines(from: mark).where(
              (l) => l.contains('Connection from') || l.contains('publickey')),
          isEmpty);
    });

    test('a key that the machine does not accept: the text of §7', () async {
      final ecdsa = sshKeyFingerprint(otherAgent.publicKeyBlob('ecdsa'));
      final node = await listed({
        'version': 1,
        'default': {'agent_key': ecdsa},
      }, socket: otherAgent.socket);
      final mark = env.sshdLogMark;

      await expectLater(
          echoOk(node),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              'Exception: Machine "local" does not accept its key ($ecdsa).')));

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(env.sshdLogLines(from: mark).join('\n'),
          isNot(contains('Accepted publickey')));
      final offered = offeredKeys(mark);
      expect(offered, contains(ecdsa),
          reason: 'the key of the map was offered');
      for (final other in ['rsa', 'ed25519']) {
        expect(names(offered, other), isFalse, reason: '$other:\n$offered');
      }
    });

    // Last test of the group: it removes the RSA key from the agent.
    test(
        'a key that the agent lost after the listing: the text of §7, and '
        'only that one key was offered', () async {
      final node = await listed({
        'version': 1,
        'default': {'agent_key': fp('rsa')},
      });
      // The identities are listed while the agent holds the key; the key
      // is removed before the connection (a lock of the vault).
      final identities = await identitiesOf(project, node);
      await env.removeAgentKey('rsa');
      final mark = env.sshdLogMark;
      final socket =
          await SSHSocket.connect('127.0.0.1', env.port, timeout: _timeout);
      final sshClient = await getSshClient(project, node, socket,
          timeout: _timeout, identities: identities);

      Object? error;
      try {
        await sshClient.run('echo ok');
      } catch (e) {
        error = e;
      } finally {
        await closeSshQuietly(sshClient);
      }

      expect(error, isNotNull, reason: 'the login must fail');
      expect(
          sshCommandErrorMessage(node, error!),
          'The SSH agent does not hold the key of machine "local" '
          '(${fp('rsa')}). If sysops filled the agent: the vault may be '
          'locked.');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(env.sshdLogLines(from: mark).join('\n'),
          isNot(contains('Accepted publickey')));
      final offered = offeredKeys(mark);
      expect(names(offered, 'rsa'), isTrue,
          reason: 'the one key of the map was offered:\n$offered');
      expect(names(offered, 'ed25519'), isFalse,
          reason: 'the other key of the agent was not offered:\n$offered');
    });
  }, skip: sshTestEnvSkip());
}
