import 'dart:io';

import 'package:nix_infra/ssh.dart' show sshAuthenticationFailedMessage;
import 'package:nix_infra/ssh_identity.dart' show publicKeyOf;
import 'package:nix_infra/ssh_key_path.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

// The public key of a key file (lib/ssh_key_path.dart) and of a machine
// with a key file (publicKeyOf), and the text of a failed authentication.

/// The path of [name] on PATH, or null.
String? _onPath(String name) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final file = File(path.join(dir, name));
    if (file.existsSync()) return file.path;
  }
  return null;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nix_infra_ssh_key_path_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File touch(String filePath) =>
      File(filePath)..createSync(recursive: true)..writeAsStringSync('x');

  group('publicKeyLineFromPrivateKey without a key', () {
    test('random text throws without echoing it', () {
      const text = 'not-a-key-0123456789';
      expect(
          () => publicKeyLineFromPrivateKey(text),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              allOf(contains('not a private key'), isNot(contains(text))))));
    });

    test('a PEM block of another kind throws', () {
      const pem = '-----BEGIN CERTIFICATE-----\n'
          'MIIBszCCAVmgAwIBAgIUQ2VydGlmaWNhdGVOb3RBS2V5MAoGCCqGSM49BAMC\n'
          '-----END CERTIFICATE-----';
      expect(() => publicKeyLineFromPrivateKey(pem),
          throwsA(isA<Exception>()));
    });
  });

  group('publicKeyOf', () {
    test('prefers <private key>.pub, trimmed, without reading the key', () async {
      final keyPath = '${tempDir.path}/keys/id';
      touch(keyPath).writeAsStringSync('not a key');
      File('$keyPath.pub')
          .writeAsStringSync('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAfake me@x\n');
      final node = ClusterNode('n1', '10.0.0.1', 1, '', sshKeyPath: keyPath);

      expect(await publicKeyOf(tempDir, node),
          equals('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAfake me@x'));
    });

    test('reads ssh/<name>.pub of the key name', () async {
      touch('${tempDir.path}/ssh/my-key');
      File('${tempDir.path}/ssh/my-key.pub')
          .writeAsStringSync('ssh-rsa AAAAB3NzaC1yc2EAAAAfake project@x\n');
      final node = ClusterNode('n1', '10.0.0.1', 1, 'my-key');

      expect(await publicKeyOf(tempDir, node),
          equals('ssh-rsa AAAAB3NzaC1yc2EAAAAfake project@x'));
    });

    test('a missing .pub and an unreadable key name the path, not the text',
        () async {
      final keyPath = '${tempDir.path}/keys/id';
      touch(keyPath).writeAsStringSync('secret-looking-text-42');
      final node = ClusterNode('n1', '10.0.0.1', 1, '', sshKeyPath: keyPath);

      expect(
          () => publicKeyOf(tempDir, node),
          throwsA(isA<Exception>().having(
              (e) => e.toString(),
              'toString()',
              allOf(contains(keyPath), contains('$keyPath.pub does not exist'),
                  isNot(contains('secret-looking-text-42'))))));
    });
  });

  group('sshAuthenticationFailedMessage', () {
    test('a key file gives the text nix-infra always gave', () {
      final node = ClusterNode('web001', '203.0.113.7', 1, 'my-key',
          sshKeyPath: './ssh/my-key');
      expect(
          sshAuthenticationFailedMessage(node),
          equals('Failed to authenticate to server "web001" at '
              '203.0.113.7:22\n'
              'Reason: SSH authentication failed - check SSH key permissions '
              'and configuration'));
    });

    test('a node without ssh_key gives the same text', () {
      final node = ClusterNode('web001', '203.0.113.7', 1, 'my-key');
      expect(
          sshAuthenticationFailedMessage(node),
          equals('Failed to authenticate to server "web001" at '
              '203.0.113.7:22\n'
              'Reason: SSH authentication failed - check SSH key permissions '
              'and configuration'));
    });
  });

  // Keys made by ssh-keygen for this run only (no key is committed). The
  // derived line must equal `ssh-keygen -y -f <file>` without the comment.
  final sshKeygen = _onPath('ssh-keygen');
  group('public key derivation against ssh-keygen', () {
    late Directory keyDir;

    /// Makes a key with ssh-keygen and returns its path.
    Future<String> makeKey(String name, List<String> typeArgs,
        {String passphrase = ''}) async {
      final keyPath = '${keyDir.path}/$name';
      final r = await Process.run(sshKeygen!, [
        '-q',
        ...typeArgs,
        '-N',
        passphrase,
        '-C',
        'nix-infra-test-key',
        '-f',
        keyPath,
      ]);
      if (r.exitCode != 0) {
        throw StateError('ssh-keygen failed for $name: ${r.stderr}');
      }
      return keyPath;
    }

    /// `ssh-keygen -y -f <keyPath>` without the comment.
    Future<String> expectedLine(String keyPath) async {
      final r = await Process.run(sshKeygen!, ['-y', '-f', keyPath]);
      if (r.exitCode != 0) {
        throw StateError('ssh-keygen -y failed: ${r.stderr}');
      }
      return (r.stdout as String).trim().split(' ').take(2).join(' ');
    }

    setUpAll(() {
      keyDir = Directory.systemTemp.createTempSync('nix_infra_ssh_keygen_');
    });

    tearDownAll(() {
      if (keyDir.existsSync()) keyDir.deleteSync(recursive: true);
    });

    final keyTypes = {
      'ed25519': ['-t', 'ed25519'],
      'RSA 2048': ['-t', 'rsa', '-b', '2048'],
      'ECDSA nistp256': ['-t', 'ecdsa', '-b', '256'],
      'RSA 2048 in the PEM (PKCS#1) format': ['-t', 'rsa', '-b', '2048', '-m', 'PEM'],
    };

    for (final entry in keyTypes.entries) {
      test('${entry.key}: equals ssh-keygen -y', () async {
        final keyPath = await makeKey(
            entry.key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_'), entry.value);
        final expected = await expectedLine(keyPath);

        final derived =
            publicKeyLineFromPrivateKey(File(keyPath).readAsStringSync());

        expect(derived, equals(expected));
        expect(derived.split(' ').length, equals(2), reason: 'no comment');
      });
    }

    test('the key type of RSA is ssh-rsa, not the signature algorithm',
        () async {
      final keyPath = await makeKey('rsa_type', ['-t', 'rsa', '-b', '2048']);
      expect(publicKeyLineFromPrivateKey(File(keyPath).readAsStringSync()),
          startsWith('ssh-rsa '));
    });

    test('a key with a passphrase throws', () async {
      final keyPath = await makeKey('with_passphrase', ['-t', 'ed25519'],
          passphrase: 'fixture-pass-1');
      expect(
          () => publicKeyLineFromPrivateKey(File(keyPath).readAsStringSync()),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              'Exception: The SSH key has a passphrase; nix-infra cannot use it')));
    });

    test('a public key is not a private key', () async {
      final keyPath = await makeKey('public_only', ['-t', 'ed25519']);
      final publicKey = File('$keyPath.pub').readAsStringSync();
      expect(() => publicKeyLineFromPrivateKey(publicKey),
          throwsA(isA<Exception>()));
    });

    test('publicKeyOf derives the key when <private key>.pub is missing',
        () async {
      final keyPath = await makeKey('no_pub', ['-t', 'ed25519']);
      final expected = await expectedLine(keyPath);
      File('$keyPath.pub').deleteSync();
      final node = ClusterNode('n1', '10.0.0.1', 1, '', sshKeyPath: keyPath);

      expect(await publicKeyOf(tempDir, node), equals(expected));
    });

    test('publicKeyOf names the passphrase when it cannot derive', () async {
      final keyPath = await makeKey('no_pub_passphrase', ['-t', 'ed25519'],
          passphrase: 'fixture-pass-1');
      File('$keyPath.pub').deleteSync();
      final node = ClusterNode('n1', '10.0.0.1', 1, '', sshKeyPath: keyPath);

      expect(
          () => publicKeyOf(tempDir, node),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              allOf(contains(keyPath), contains('has a passphrase')))));
    });
  }, skip: sshKeygen == null ? 'ssh-keygen is not on PATH' : false);
}
