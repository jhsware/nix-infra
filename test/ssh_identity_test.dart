// identitiesOf, publicKeyOf and sshCommand of lib/ssh_identity.dart
// (docs/design/ssh_agent_keys.md §6.2, §7): for a machine with a key file
// (the results of before), with an agent key (a fake agent on a Unix
// socket), and with a key that is not available. The typed errors and their
// texts of lib/ssh_key_errors.dart. Nothing here connects to a machine.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:nix_infra/ssh_agent.dart';
import 'package:nix_infra/ssh_identity.dart';
import 'package:nix_infra/ssh_key_errors.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'support/fake_ssh_agent.dart';
import 'support/ssh_test_env.dart' show findSshTool;

/// The agent lists [keys] (comment `comment`) and refuses every other
/// request.
void serveKeys(FakeSshAgent agent, List<Uint8List> keys) {
  agent.answer = (request) => FakeAnswer(frame(
      request.first == SshAgentMessage.requestIdentities
          ? [
              SshAgentMessage.identitiesAnswer,
              ...uint32(keys.length),
              for (final key in keys) ...[
                ...sshString(key),
                ...sshString(utf8.encode('comment')),
              ],
            ]
          : [SshAgentMessage.failure]));
}

/// A [NodeKeyException] of type [T] whose text is [text] and names nothing
/// of the folders [dirs].
TypeMatcher<T> keyError<T extends NodeKeyException>(
        String text, List<String> dirs) =>
    isA<T>()
        .having((e) => e.message, 'message', text)
        .having((e) => e.toString(), 'toString()', text)
        .having((e) => [for (final d in dirs) e.message.contains(d)],
            'names a folder', everyElement(isFalse));

/// The temporary folders of [sshCommand] that exist now.
Set<String> sshCommandTempDirs() => {
      for (final entity in Directory.systemTemp.listSync())
        if (path.basename(entity.path).startsWith('nix-infra-ssh-'))
          entity.path,
    };

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_ssh_identity_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// web-1, with the key file `ssh/<keyName>` of the project (or
  /// [sshKeyPath]) and the key source [keySource].
  ClusterNode machine(
          {String keyName = 'test-key',
          String? sshKeyPath,
          NodeKeySource keySource = const KeyFileSource()}) =>
      ClusterNode('web-1', '192.0.2.1', 1, keyName,
          sshKeyPath: sshKeyPath, keySource: keySource);

  File keyFile(String name) =>
      File(path.join(dir.path, 'ssh', name))..parent.createSync(recursive: true);

  group('a machine with a key file', () {
    test('a missing key file: the text of design §7, without the path',
        () async {
      await expectLater(
          identitiesOf(dir, machine()),
          throwsA(keyError<NodeKeyFileException>(
                  'The SSH key file of machine "web-1" does not exist.',
                  [dir.path])
              .having((e) => e.problem, 'problem', NodeKeyFileProblem.missing)
              .having((e) => e.path, 'path', '${dir.path}/ssh/test-key')));
    });

    test('an empty key name (a folder): the key file does not exist',
        () async {
      await expectLater(
          identitiesOf(dir, machine(keyName: '')),
          throwsA(isA<NodeKeyFileException>().having(
              (e) => e.problem, 'problem', NodeKeyFileProblem.missing)));
    });

    test('a file that is not a private key: no byte of it in the text',
        () async {
      keyFile('test-key').writeAsStringSync('secret-looking-text-42');
      await expectLater(
          identitiesOf(dir, machine()),
          throwsA(keyError<NodeKeyFileException>(
                  'The SSH key file of machine "web-1" is not a private key '
                  'that nix-infra can read.',
                  [dir.path, 'secret-looking-text-42'])
              .having(
                  (e) => e.problem, 'problem', NodeKeyFileProblem.invalid)));
    });

    test('publicKeyOf reads <key file>.pub, as before', () async {
      keyFile('test-key').writeAsStringSync('not read');
      keyFile('test-key.pub')
          .writeAsStringSync('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAfake me@x\n');
      expect(await publicKeyOf(dir, machine()),
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAfake me@x');
    });

    test('sshCommand: the string of before, and no temporary file', () async {
      final before = sshCommandTempDirs();
      final ssh = await sshCommand(dir, machine());
      expect(ssh.command,
          'ssh -i "${dir.path}/ssh/test-key" -o StrictHostKeyChecking=no '
          'root@192.0.2.1');
      expect(ssh.publicKeyFile, isNull);
      expect(sshCommandTempDirs(), before);
      await ssh.dispose();

      final other = await sshCommand(dir, machine(sshKeyPath: '/opt/keys/k'));
      expect(other.command,
          'ssh -i "/opt/keys/k" -o StrictHostKeyChecking=no root@192.0.2.1');
    });

    final sshKeygen = findSshTool('ssh-keygen');
    group('made by ssh-keygen', () {
      Future<File> makeKey(String name, {String passphrase = ''}) async {
        final file = keyFile(name);
        final r = await Process.run(sshKeygen!, [
          '-q', '-t', 'rsa', '-b', '2048', '-N', passphrase, //
          '-C', 'nix-infra-test', '-f', file.path,
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return file;
      }

      test('identitiesOf reads the key file, as before', () async {
        final file = await makeKey('test-key');
        final expected = SSHKeyPair.fromPem(file.readAsStringSync().trim());

        final identities = await identitiesOf(dir, machine());

        expect(identities, hasLength(1));
        expect(identities.single.toPublicKey().encode(),
            expected.single.toPublicKey().encode());
      });

      test('a key file with a passphrase: its text', () async {
        await makeKey('test-key', passphrase: 'fixture-pass-1');
        await expectLater(
            identitiesOf(dir, machine()),
            throwsA(keyError<NodeKeyFileException>(
                'The SSH key file of machine "web-1" has a passphrase; '
                'nix-infra cannot use it.',
                [dir.path, 'fixture-pass-1'])));
      });
    }, skip: sshKeygen == null ? 'ssh-keygen is not on PATH' : false);
  });

  group('a machine with an agent key', () {
    late FakeSshAgent agent;
    late Uint8List key;
    late String fingerprint;

    setUp(() async {
      agent = await FakeSshAgent.start();
      key = fakeKeyBlob('ssh-ed25519');
      fingerprint = sshKeyFingerprint(key);
      serveKeys(agent, [fakeKeyBlob('ssh-rsa', keyBytes: 257), key]);
    });

    tearDown(() => agent.stop());

    ClusterNode agentMachine({String? fp, String? socket}) => machine(
        keySource:
            AgentKeySource(fp ?? fingerprint, agentSocket: socket ?? agent.socketPath));

    List<String> dirs() => [dir.path, agent.dir.path];

    test('identitiesOf gives the one key of its fingerprint', () async {
      // No key file exists: it is not read.
      final identities = await identitiesOf(dir, agentMachine());

      expect(identities, hasLength(1));
      expect(identities.single.type, 'ssh-ed25519');
      expect(identities.single.toPublicKey().encode(), key);
      expect(agent.requests, [
        [SshAgentMessage.requestIdentities]
      ]);
    });

    test('identitiesOf asks the agent at each call', () async {
      await identitiesOf(dir, agentMachine());
      await identitiesOf(dir, agentMachine());
      expect(agent.requests, hasLength(2));
    });

    test('agentSocket wins over the socket of the key source', () async {
      final node = machine(keySource: AgentKeySource(fingerprint));
      final identities =
          await identitiesOf(dir, node, agentSocket: agent.socketPath);
      expect(identities.single.toPublicKey().encode(), key);
    });

    test('publicKeyOf: <type> <base64 of the blob> from the agent', () async {
      expect(await publicKeyOf(dir, agentMachine()),
          'ssh-ed25519 ${base64.encode(key)}');
    });

    test('sshCommand: the agent, that one key, no forwarding', () async {
      final ssh = await sshCommand(dir, agentMachine());
      try {
        final file = ssh.publicKeyFile!;
        expect(
            ssh.command,
            'ssh -o "IdentityAgent=${agent.socketPath}" -o IdentitiesOnly=yes '
            '-o ForwardAgent=no -i "$file" -o StrictHostKeyChecking=no '
            'root@192.0.2.1');
        expect(ssh.command.split(' '), isNot(contains('-A')));
        expect(File(file).readAsStringSync(),
            'ssh-ed25519 ${base64.encode(key)}\n');
        expect(File(file).statSync().mode & 0x1ff, 0x180, reason: 'mode 600');
        expect(file, isNot(startsWith(dir.path)));
      } finally {
        await ssh.dispose();
      }
      expect(File(ssh.publicKeyFile!).existsSync(), isFalse);
      expect(Directory(path.dirname(ssh.publicKeyFile!)).existsSync(), isFalse);
    });

    test('withSshCommand: the file exists during the command, not after',
        () async {
      String? file;
      final result = await withSshCommand(dir, agentMachine(), (command) async {
        file = RegExp(r'-i "([^"]+)"').firstMatch(command)!.group(1);
        expect(File(file!).existsSync(), isTrue);
        return 'ran';
      });
      expect(result, 'ran');
      expect(File(file!).existsSync(), isFalse);
    });

    test('withSshCommand: the file is deleted after an error too', () async {
      String? file;
      await expectLater(
          withSshCommand(dir, agentMachine(), (command) async {
            file = RegExp(r'-i "([^"]+)"').firstMatch(command)!.group(1);
            throw StateError('the command failed');
          }),
          throwsA(isA<StateError>()));
      expect(file, isNotNull);
      expect(File(file!).existsSync(), isFalse);
      expect(Directory(path.dirname(file!)).existsSync(), isFalse);
    });

    test('a fingerprint that the agent does not hold: its text', () async {
      final missing = sshKeyFingerprint(fakeKeyBlob('ssh-ed25519'));
      final text = 'The SSH agent does not hold the key of machine "web-1" '
          '($missing). If sysops filled the agent: the vault may be locked.';
      final node = agentMachine(fp: missing);
      final before = sshCommandTempDirs();

      await expectLater(identitiesOf(dir, node),
          throwsA(keyError<NodeKeyNotInAgentException>(text, dirs())));
      await expectLater(publicKeyOf(dir, node),
          throwsA(keyError<NodeKeyNotInAgentException>(text, dirs())));
      await expectLater(sshCommand(dir, node),
          throwsA(keyError<NodeKeyNotInAgentException>(text, dirs())));
      expect(sshCommandTempDirs(), before, reason: 'no file is written');
    });

    test('an agent that refuses to list: the same text', () async {
      agent.answer = (_) => FakeAnswer(frame([SshAgentMessage.failure]));
      await expectLater(
          identitiesOf(dir, agentMachine()),
          throwsA(keyError<NodeKeyNotInAgentException>(
              'The SSH agent does not hold the key of machine "web-1" '
              '($fingerprint). If sysops filled the agent: the vault may be '
              'locked.',
              dirs())));
    });

    test('an agent that cannot be reached: its text', () async {
      final node =
          agentMachine(socket: path.join(agent.dir.path, 'missing.sock'));
      const text = 'The SSH agent of this session cannot be reached. The key '
          'of machine "web-1" is not available.';
      await expectLater(identitiesOf(dir, node),
          throwsA(keyError<NodeKeyAgentUnreachableException>(text, dirs())));
      await expectLater(publicKeyOf(dir, node),
          throwsA(keyError<NodeKeyAgentUnreachableException>(text, dirs())));
    });

    test('no SSH_AUTH_SOCK: its text, for each function, and no file',
        () async {
      final node = machine(keySource: AgentKeySource(fingerprint));
      const text = 'SSH_KEY_MAP_PATH is set but SSH_AUTH_SOCK is not.';
      final before = sshCommandTempDirs();

      await expectLater(identitiesOf(dir, node),
          throwsA(keyError<NodeKeyNoAgentSocketException>(text, dirs())));
      await expectLater(publicKeyOf(dir, node),
          throwsA(keyError<NodeKeyNoAgentSocketException>(text, dirs())));
      await expectLater(sshCommand(dir, node),
          throwsA(keyError<NodeKeyNoAgentSocketException>(text, dirs())));
      expect(sshCommandTempDirs(), before);
      expect(agent.connections, 0);
    });
  });

  group('a machine whose key is not available', () {
    setUp(() {
      // A key file that would be used if the key source fell through.
      keyFile('test-key').writeAsStringSync('not a key');
      keyFile('test-key.pub').writeAsStringSync('ssh-ed25519 AAAAfake x');
    });

    for (final (source, text) in [
      (
        const UnavailableKeySource('secrets_locked, ring interactive'),
        'The SSH key of machine "web-1" is not available (secrets_locked, '
            'ring interactive).'
      ),
      (
        const KeyMapUnreadableSource('The key map cannot be read.'),
        'The key map of this session cannot be read. The key of machine '
            '"web-1" is not available.'
      ),
    ]) {
      test('$source: each function throws its text, no key file is used',
          () async {
        final node = machine(keySource: source);
        final before = sshCommandTempDirs();
        final matcher = throwsA(isA<NodeKeyException>()
            .having((e) => e.message, 'message', text)
            .having((e) => e.toString(), 'toString()', text));

        await expectLater(identitiesOf(dir, node), matcher);
        await expectLater(publicKeyOf(dir, node), matcher);
        await expectLater(sshCommand(dir, node), matcher);
        expect(sshCommandTempDirs(), before);
      });
    }
  });

  group('nodeKeyErrorOf', () {
    const fp = 'SHA256:u2l0c8QfR1vN0mJ5rT8hD4kX9aYb3Wq7eZs6PpLo1Hg';
    final agentNode =
        machine(keySource: const AgentKeySource(fp, agentSocket: '/x.sock'));

    test('finds the refusal of the agent inside the errors of dartssh2', () {
      final error = SSHAuthAbortError(
          'Connection closed before authentication',
          SSHInternalError(const SshAgentRefusedException(fingerprint: fp)));
      expect(
          nodeKeyErrorOf(agentNode, error),
          isA<NodeKeyNotInAgentException>()
              .having((e) => e.fingerprint, 'fingerprint', fp));
    });

    test('a failed login of an agent key: the machine does not accept it', () {
      expect(
          nodeKeyErrorOf(agentNode, SSHAuthFailError('All methods failed'))
              ?.message,
          'Machine "web-1" does not accept its key ($fp).');
    });

    test('a failed login of a key file is not about the key', () {
      expect(nodeKeyErrorOf(machine(), SSHAuthFailError('failed')), isNull);
    });

    test('another error of the agent names it, without a path', () {
      final error = SSHAuthAbortError('closed',
          SSHInternalError(const SshAgentTimeoutException(Duration(seconds: 3))));
      expect(
          nodeKeyErrorOf(agentNode, error)?.message,
          'The SSH agent of this session failed for the key of machine '
          '"web-1" ($fp): The SSH agent did not answer within 3 s.');
    });

    test('an error of the network is not about the key', () {
      expect(
          nodeKeyErrorOf(
              agentNode, const SocketException('Connection refused')),
          isNull);
    });
  });
}
