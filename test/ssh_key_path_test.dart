import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/ssh.dart' show sshAuthenticationFailedMessage;
import 'package:nix_infra/ssh_identity.dart' show publicKeyOf;
import 'package:nix_infra/ssh_key_path.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

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
  /// DotEnv() does not include the platform environment, so a SSH_KEY_PATH
  /// of the developer's shell does not leak into these tests.
  DotEnv envOf(Map<String, String> values) => DotEnv()..addAll(values);

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nix_infra_ssh_key_path_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File touch(String filePath) =>
      File(filePath)..createSync(recursive: true)..writeAsStringSync('x');

  group('resolveSshKeyPath', () {
    test('unset gives null', () {
      expect(resolveSshKeyPath(envOf({}), tempDir), isNull);
    });

    test('empty or blank gives null', () {
      expect(resolveSshKeyPath(envOf({'SSH_KEY_PATH': ''}), tempDir), isNull);
      expect(
          resolveSshKeyPath(envOf({'SSH_KEY_PATH': '  '}), tempDir), isNull);
    });

    test('an absolute path is used, normalized', () {
      final key = touch('${tempDir.path}/keys/id_ed25519');
      expect(
          resolveSshKeyPath(
              envOf({'SSH_KEY_PATH': '${tempDir.path}/keys/../keys/id_ed25519'}),
              tempDir),
          equals(key.path));
    });

    test('a relative path is relative to the project folder', () {
      final project = Directory('${tempDir.path}/project')..createSync();
      final key = touch('${project.path}/keys/id_ed25519');
      expect(
          resolveSshKeyPath(
              envOf({'SSH_KEY_PATH': 'keys/id_ed25519'}), project),
          equals(key.path));
      expect(
          resolveSshKeyPath(
              envOf({'SSH_KEY_PATH': './keys/id_ed25519'}), project),
          equals(key.path));
    });

    test('a leading ~/ is the home directory', () {
      final home = '${tempDir.path}/home';
      final key = touch('$home/.ssh/id_ed25519');
      expect(
          resolveSshKeyPath(envOf({'SSH_KEY_PATH': '~/.ssh/id_ed25519'}),
              Directory('${tempDir.path}/project'),
              homeDir: home),
          equals(key.path));
    });

    test('surrounding blanks are ignored', () {
      final key = touch('${tempDir.path}/id_ed25519');
      expect(
          resolveSshKeyPath(
              envOf({'SSH_KEY_PATH': ' ${tempDir.path}/id_ed25519 '}), tempDir),
          equals(key.path));
    });

    test('a missing file throws before any connection', () {
      final missing = '${tempDir.path}/run/ssh-keys/p/k-fp';
      expect(
          () => resolveSshKeyPath(envOf({'SSH_KEY_PATH': missing}), tempDir),
          throwsA(isA<Exception>().having(
              (e) => e.toString(),
              'toString()',
              'Exception: SSH_KEY_PATH names a file that does not exist: '
                  '$missing. If a sysops terminal set it: unlock the vault '
                  'and open a new terminal.')));
    });

    test('a directory is not a key file', () {
      Directory('${tempDir.path}/keys').createSync();
      expect(
          () => resolveSshKeyPath(
              envOf({'SSH_KEY_PATH': '${tempDir.path}/keys'}), tempDir),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              contains('SSH_KEY_PATH names a file that does not exist'))));
    });

    test('a missing file under ~/ names the expanded path', () {
      final home = '${tempDir.path}/home';
      expect(
          () => resolveSshKeyPath(
              envOf({'SSH_KEY_PATH': '~/.ssh/missing'}), tempDir,
              homeDir: home),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              contains('does not exist: $home/.ssh/missing.'))));
    });
  });

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
      final node = ClusterNode('n1', '10.0.0.1', 1, '',
          sshKeyPath: keyPath, sshKeyPathFromEnv: true);

      expect(await publicKeyOf(tempDir, node),
          equals('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAfake me@x'));
    });

    test('keeps the result of ssh/<name>.pub for a project without '
        'SSH_KEY_PATH', () async {
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
    test('with SSH_KEY_PATH it names the key of SSH_KEY_PATH', () {
      final node = ClusterNode('web001', '203.0.113.7', 1, '',
          sshKeyPath: '/k', sshKeyPathFromEnv: true);
      expect(
          sshAuthenticationFailedMessage(node),
          equals('Failed to authenticate to server "web001" at '
              '203.0.113.7:22\n'
              'Reason: the machine does not accept the key of SSH_KEY_PATH. '
              'It may belong to another SSH key (in sysops: open a terminal '
              'with the key of this machine).'));
    });

    test('without SSH_KEY_PATH the text is unchanged', () {
      final node = ClusterNode('web001', '203.0.113.7', 1, 'my-key',
          sshKeyPath: './ssh/my-key');
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
      final node = ClusterNode('n1', '10.0.0.1', 1, '',
          sshKeyPath: keyPath, sshKeyPathFromEnv: true);

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
