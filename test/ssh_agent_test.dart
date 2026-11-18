// The ssh-agent client of lib/ssh_agent.dart (docs/design/ssh_agent_keys.md
// §6.1, §10): against a fake agent on a Unix socket (always run).
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nix_infra/ssh_agent.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'support/fake_ssh_agent.dart';

/// An [SshAgentException] of type [T] whose texts name nothing of the
/// folder [dir] of the socket (design §7).
TypeMatcher<T> agentError<T extends SshAgentException>(String dir) =>
    isA<T>()
        .having((e) => e.toString(), 'toString()', isNot(contains(dir)))
        .having((e) => e.message, 'message', isNot(contains(dir)));

/// The fingerprint of [blob] as `ssh-add -l` prints it, made here without
/// the code under test.
String expectedFingerprint(List<int> blob) {
  final hash = base64.encode(sha256.convert(blob).bytes);
  expect(hash, endsWith('='), reason: 'a SHA-256 in base64 has one pad');
  return 'SHA256:${hash.substring(0, hash.length - 1)}';
}

void main() {
  group('fake agent', () {
    late FakeSshAgent agent;
    late SshAgentClient client;

    setUp(() async {
      agent = await FakeSshAgent.start();
      client = SshAgentClient(agent.socketPath,
          timeout: const Duration(seconds: 5));
    });

    tearDown(() => agent.stop());

    test('lists two identities', () async {
      final ed25519 = fakeKeyBlob('ssh-ed25519');
      final rsa = fakeKeyBlob('ssh-rsa', keyBytes: 257);
      agent.answer = (_) => FakeAnswer(frame([
            SshAgentMessage.identitiesAnswer,
            ...uint32(2),
            ...sshString(ed25519),
            ...sshString(utf8.encode('first')),
            ...sshString(rsa),
            ...sshString(utf8.encode('zweiter Schlüssel')),
          ]));

      final identities = await client.listIdentities();

      expect(agent.requests.single, [SshAgentMessage.requestIdentities]);
      expect(identities, hasLength(2));
      expect(identities[0].keyBlob, ed25519);
      expect(identities[0].comment, 'first');
      expect(identities[0].keyType, 'ssh-ed25519');
      expect(identities[0].fingerprint, expectedFingerprint(ed25519));
      expect(
          identities[0].fingerprint, matches(r'^SHA256:[A-Za-z0-9+/]{43}$'));
      expect(identities[0].publicKeyLine,
          'ssh-ed25519 ${base64.encode(ed25519)}');
      expect(identities[1].keyBlob, rsa);
      expect(identities[1].comment, 'zweiter Schlüssel');
      expect(identities[1].keyType, 'ssh-rsa');
      expect(identities[1].fingerprint, expectedFingerprint(rsa));
    });

    test('an agent with no keys: an empty list', () async {
      agent.answer = (_) =>
          FakeAnswer(frame([SshAgentMessage.identitiesAnswer, ...uint32(0)]));
      expect(await client.listIdentities(), isEmpty);
    });

    test('sign: the request holds the key blob, the data and the flags',
        () async {
      final key = fakeKeyBlob('ssh-rsa');
      final data = Uint8List.fromList(utf8.encode('data to sign'));
      final signature = fakeSignatureBlob('rsa-sha2-512', [1, 2, 3, 4]);
      agent.answer = (_) => FakeAnswer(
          frame([SshAgentMessage.signResponse, ...sshString(signature)]));

      final result =
          await client.sign(key, data, flags: SshAgentSignFlags.rsaSha512);

      expect(result, signature);
      expect(agent.requests.single, [
        SshAgentMessage.signRequest,
        ...sshString(key),
        ...sshString(data),
        ...uint32(4),
      ]);
    });

    test('sign without flags sends the flags 0', () async {
      final key = fakeKeyBlob('ssh-ed25519');
      agent.answer = (_) => FakeAnswer(frame([
            SshAgentMessage.signResponse,
            ...sshString(fakeSignatureBlob('ssh-ed25519', [9])),
          ]));
      await client.sign(key, Uint8List.fromList([1]));
      expect(agent.requests.single.sublist(agent.requests.single.length - 4),
          [0, 0, 0, 0]);
    });

    test('SSH_AGENT_FAILURE to a sign request names the fingerprint',
        () async {
      final key = fakeKeyBlob('ssh-ed25519');
      agent.answer = (_) => FakeAnswer(frame([SshAgentMessage.failure]));
      await expectLater(
          client.sign(key, Uint8List.fromList([1])),
          throwsA(agentError<SshAgentRefusedException>(agent.dir.path)
              .having((e) => e.fingerprint, 'fingerprint',
                  expectedFingerprint(key))
              .having((e) => e.message, 'message',
                  contains(expectedFingerprint(key)))));
    });

    test('SSH_AGENT_FAILURE to a list request', () async {
      agent.answer = (_) => FakeAnswer(frame([SshAgentMessage.failure]));
      await expectLater(
          client.listIdentities(),
          throwsA(agentError<SshAgentRefusedException>(agent.dir.path)
              .having((e) => e.fingerprint, 'fingerprint', isNull)));
    });

    test('a cut message: the connection ends before the announced length',
        () async {
      agent.answer = (_) => FakeAnswer(
          [...uint32(50), SshAgentMessage.identitiesAnswer, ...uint32(1)]);
      await expectLater(
          client.listIdentities(),
          throwsA(agentError<SshAgentCutMessageException>(agent.dir.path)
              .having((e) => e.closed, 'closed', isTrue)));
    });

    test('a closed connection: the agent closes without an answer', () async {
      agent.answer = (_) => const FakeAnswer([]);
      await expectLater(
          client.listIdentities(),
          throwsA(agentError<SshAgentCutMessageException>(agent.dir.path)
              .having((e) => e.closed, 'closed', isTrue)));
    });

    test('a cut message: a field runs past the end of the answer', () async {
      // One identity whose key blob announces 100 bytes and has none.
      agent.answer = (_) => FakeAnswer(frame(
          [SshAgentMessage.identitiesAnswer, ...uint32(1), ...uint32(100)]));
      await expectLater(
          client.listIdentities(),
          throwsA(agentError<SshAgentCutMessageException>(agent.dir.path)
              .having((e) => e.closed, 'closed', isFalse)));
    });

    test('an answer over 256 KiB is refused before its body is read',
        () async {
      // Only the length field; the connection stays open and no body comes.
      agent.answer = (_) =>
          FakeAnswer(uint32(sshAgentMaxMessageLength + 1), close: false);
      await expectLater(
          client.listIdentities().timeout(const Duration(seconds: 2)),
          throwsA(agentError<SshAgentMessageTooLargeException>(agent.dir.path)
              .having((e) => e.sent, 'sent', isFalse)
              .having((e) => e.length, 'length',
                  sshAgentMaxMessageLength + 1)));
    });

    test('an answer of exactly 256 KiB is read', () async {
      // type byte + string length + signature = 256 KiB
      final signature = Uint8List(sshAgentMaxMessageLength - 1 - 4);
      agent.answer = (_) => FakeAnswer(
          frame([SshAgentMessage.signResponse, ...sshString(signature)]));
      final result =
          await client.sign(fakeKeyBlob('ssh-ed25519'), Uint8List(1));
      expect(result, hasLength(signature.length));
    });

    test('a request over 256 KiB is not sent', () async {
      final key = fakeKeyBlob('ssh-ed25519');
      // type byte + key string + data string + flags = 256 KiB + 1
      final data = Uint8List(
          sshAgentMaxMessageLength + 1 - 1 - (4 + key.length) - 4 - 4);
      await expectLater(
          client.sign(key, data),
          throwsA(agentError<SshAgentMessageTooLargeException>(agent.dir.path)
              .having((e) => e.sent, 'sent', isTrue)
              .having((e) => e.length, 'length',
                  sshAgentMaxMessageLength + 1)));
      expect(agent.connections, 0);

      // One byte less is sent.
      agent.answer = (_) => FakeAnswer(frame([
            SshAgentMessage.signResponse,
            ...sshString(fakeSignatureBlob('ssh-ed25519', [1])),
          ]));
      await client.sign(key, data.sublist(1));
      expect(agent.requests.single, hasLength(sshAgentMaxMessageLength));
    });

    test('an answer of another message type', () async {
      agent.answer = (_) => FakeAnswer(frame([99]));
      await expectLater(
          client.listIdentities(),
          throwsA(
              agentError<SshAgentUnexpectedMessageException>(agent.dir.path)
                  .having((e) => e.messageType, 'messageType', 99)));
    });

    test('an agent that never answers: the timeout', () async {
      agent.answer = (_) => const FakeAnswer([], close: false);
      final quick = SshAgentClient(agent.socketPath,
          timeout: const Duration(milliseconds: 300));
      await expectLater(
          quick.listIdentities(),
          throwsA(agentError<SshAgentTimeoutException>(agent.dir.path)
              .having((e) => e.message, 'message', contains('300 ms'))));
      // The client closed the connection.
      await agent.waitUntil(() => agent.closedByClient == 1);
    });

    test('a socket path that does not exist: no path in the text', () async {
      final missing = path.join(agent.dir.path, 'missing.sock');
      await expectLater(
          SshAgentClient(missing).listIdentities(),
          throwsA(agentError<SshAgentUnreachableException>(agent.dir.path)
              .having((e) => e.toString(), 'toString()',
                  isNot(contains('missing.sock')))));
    });

    test('a socket that nobody listens on any more', () async {
      final socketPath = path.join(agent.dir.path, 'closed.sock');
      final server = await ServerSocket.bind(
          InternetAddress(socketPath, type: InternetAddressType.unix), 0);
      await server.close();
      await expectLater(SshAgentClient(socketPath).listIdentities(),
          throwsA(agentError<SshAgentUnreachableException>(agent.dir.path)));
    });

    test('one connection per request, closed by the client', () async {
      final key = fakeKeyBlob('ssh-ed25519');
      agent.answer = (request) => FakeAnswer(frame(
          request.first == SshAgentMessage.requestIdentities
              ? [
                  SshAgentMessage.identitiesAnswer,
                  ...uint32(1),
                  ...sshString(key),
                  ...sshString([]),
                ]
              : [
                  SshAgentMessage.signResponse,
                  ...sshString(fakeSignatureBlob('ssh-ed25519', [1])),
                ]));

      await client.listIdentities();
      await client.sign(key, Uint8List(8));
      await client.listIdentities();

      expect(agent.connections, 3);
      expect(agent.requests, hasLength(3));
      await agent.waitUntil(() => agent.closedByClient == 3);
    });
  });
}
