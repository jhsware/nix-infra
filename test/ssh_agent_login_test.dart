// Login through the agent identity of lib/ssh_agent.dart against a local
// sshd (docs/design/ssh_agent_keys.md §10): dartssh2 4.1 with a key that
// only a real ssh-agent holds, for an RSA 2048 key and an Ed25519 key.
// Skipped when `ssh-agent`, `ssh-add`, `ssh-keygen` or `sshd` is missing.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:nix_infra/ssh_agent.dart';
import 'package:test/test.dart';

import 'support/ssh_test_env.dart';

/// The error inside the errors of dartssh2 that wrap it.
Object unwrapSshError(Object error) => switch (error) {
      SSHAuthAbortError(reason: final reason?) => unwrapSshError(reason),
      SSHInternalError(error: final inner) => unwrapSshError(inner),
      SSHSocketError(error: final inner) => unwrapSshError(inner),
      _ => error,
    };

void main() {
  group('login through the agent identity', () {
    late SshTestEnv env;

    setUpAll(() async {
      env = await SshTestEnv.start(keys: ['rsa', 'ed25519']);
    });

    tearDownAll(() => env.stop());

    Future<SSHClient> connect(SSHIdentity identity) async => SSHClient(
          await SSHSocket.connect('127.0.0.1', env.port),
          username: env.user,
          identities: [identity],
          authTimeout: const Duration(seconds: 20),
        );

    for (final (name, algorithm) in [
      ('rsa', 'rsa-sha2-512'),
      ('ed25519', 'ssh-ed25519'),
    ]) {
      test('$name: logs in with the key of the agent and runs echo ok',
          () async {
        final fingerprint = sshKeyFingerprint(env.publicKeyBlob(name));
        final identity = await agentIdentityFor(env.agentSocket, fingerprint);
        expect(identity.type, algorithm);

        final mark = env.sshdLogMark;
        final client = await connect(identity);
        try {
          final result = await client.runWithResult('echo ok');
          expect(utf8.decode(result.stdout).trim().split('\n').last, 'ok');
          expect(result.exitCode, 0);
        } finally {
          await client.close();
        }

        final accepted = await env.waitForSshdLog(
            (l) => l.contains('Accepted publickey'),
            from: mark);
        expect(accepted, contains(fingerprint));
        // sshd (LogLevel DEBUG2) names the algorithm that the client sent.
        expect(
            env
                .sshdLogLines(from: mark)
                .where((l) => l.contains('public key $algorithm ')),
            isNotEmpty,
            reason: env.sshdLogLines(from: mark).join('\n'));
      });
    }

    test(
        'a fingerprint that the agent does not hold: the typed error, and no '
        'login is tried', () async {
      final mark = env.sshdLogMark;
      final missing = sshKeyFingerprint(
          Uint8List.fromList(utf8.encode('not a key of the agent')));
      await expectLater(
          agentIdentityFor(env.agentSocket, missing),
          throwsA(isA<SshAgentKeyNotFoundException>()
              .having((e) => e.fingerprint, 'fingerprint', missing)
              .having((e) => e.toString(), 'toString()',
                  isNot(contains(env.dir.path)))));

      // No identity, so no connection: sshd saw none.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
          env.sshdLogLines(from: mark).where(
              (l) => l.contains('Connection from') || l.contains('publickey')),
          isEmpty);
    });

    // Last test of the group: it removes the RSA key from the agent.
    test(
        'a key that the agent lost after the listing: the login fails with '
        'the refusal of the agent, and no other key is tried', () async {
      final rsa = sshKeyFingerprint(env.publicKeyBlob('rsa'));
      final ed25519 = sshKeyFingerprint(env.publicKeyBlob('ed25519'));
      final ed25519Blob = env.publicKeyLine('ed25519').split(' ')[1];
      final identity = await agentIdentityFor(env.agentSocket, rsa);
      await env.removeAgentKey('rsa');

      final mark = env.sshdLogMark;
      final client = await connect(identity);
      Object? error;
      try {
        await client.authenticated;
      } catch (e) {
        error = e;
      } finally {
        await client.close();
      }
      expect(error, isNotNull, reason: 'the login must fail');
      expect(
          unwrapSshError(error!),
          isA<SshAgentRefusedException>()
              .having((e) => e.fingerprint, 'fingerprint', rsa));

      await Future<void>.delayed(const Duration(milliseconds: 300));
      final log = env.sshdLogLines(from: mark);
      expect(log.where((l) => l.contains('Accepted publickey')), isEmpty);
      expect(
          log.where((l) => l.contains(ed25519) || l.contains(ed25519Blob)),
          isEmpty,
          reason: 'the Ed25519 key of the agent must not be offered');
    });
  }, skip: sshTestEnvSkip());
}
