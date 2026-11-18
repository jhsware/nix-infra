import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart'
    show SSHIdentity, SSHRawHostKey, SSHRawSignature;

// A client for the SSH agent protocol (RFC 9987) over the Unix-domain socket
// of an agent (docs/design/ssh_agent_keys.md §6.1). It sends two requests:
// list the identities, and sign. [agentIdentityFor] makes a dartssh2
// identity that signs through the agent with the key of one fingerprint.
//
// dartssh2 4.1 has no such client. It has the other side (an agent that
// answers over an SSH channel, for agent forwarding) and exports the names
// `SSHAgentProtocol`, `SSHAgentHandler`, `SSHKeyPairAgent` and
// `SSHAgentChannel`; this file declares none of them.
//
// The caller passes the socket path (the value of `SSH_AUTH_SOCK`); this
// file reads no variable. No text of this file names the socket path: an
// MCP tool result must not show it (design §7).

/// The largest agent message, in either direction (design §6.1): the value
/// of the length field, which counts the type byte and the body.
const sshAgentMaxMessageLength = 256 * 1024;

/// How long one request may take (connect, send, answer) when the caller
/// gives no timeout. An agent may ask its user to confirm a signature
/// (`ssh-add -c`), so it is not short.
const sshAgentDefaultTimeout = Duration(seconds: 30);

/// The message numbers of RFC 9987 that this client uses.
abstract final class SshAgentMessage {
  static const failure = 5;
  static const requestIdentities = 11;
  static const identitiesAnswer = 12;
  static const signRequest = 13;
  static const signResponse = 14;
}

/// The flags of a sign request (RFC 9987): the hash of an RSA signature.
abstract final class SshAgentSignFlags {
  static const none = 0;

  /// `SSH_AGENT_RSA_SHA2_256`: an RSA signature `rsa-sha2-256`.
  static const rsaSha256 = 2;

  /// `SSH_AGENT_RSA_SHA2_512`: an RSA signature `rsa-sha2-512`.
  static const rsaSha512 = 4;
}

/// An error of the agent or of its protocol.
///
/// [message] and [toString] never hold the socket path (design §7), so an
/// MCP tool may show them. The subclasses let a caller choose its own text.
sealed class SshAgentException implements Exception {
  const SshAgentException();

  /// What went wrong, as one sentence.
  String get message;

  @override
  String toString() => 'SshAgentException: $message';
}

/// The socket of the agent does not exist, or nothing accepts a connection
/// on it.
final class SshAgentUnreachableException extends SshAgentException {
  const SshAgentUnreachableException();

  @override
  String get message => 'The SSH agent cannot be reached.';
}

/// The agent answered `SSH_AGENT_FAILURE`.
///
/// For a sign request [fingerprint] names the key: the agent does not hold
/// it (any more), or refuses to sign with it. Null for a list request.
final class SshAgentRefusedException extends SshAgentException {
  const SshAgentRefusedException({this.fingerprint});

  final String? fingerprint;

  @override
  String get message => fingerprint == null
      ? 'The SSH agent refused to list its keys.'
      : 'The SSH agent does not hold the key $fingerprint, '
          'or refused to sign with it.';
}

/// An answer that is not complete: the connection ended before the length
/// that the answer announced ([closed]), or a field of the answer runs past
/// its end.
final class SshAgentCutMessageException extends SshAgentException {
  const SshAgentCutMessageException({this.closed = true});

  /// True when the connection ended before the answer was complete.
  final bool closed;

  @override
  String get message => closed
      ? 'The SSH agent closed the connection before its answer was complete.'
      : 'The SSH agent sent an answer that is cut off.';
}

/// A message larger than [sshAgentMaxMessageLength]: a request, which is
/// then not sent ([sent] is true), or an answer of the agent, which is
/// refused before its body is read.
final class SshAgentMessageTooLargeException extends SshAgentException {
  const SshAgentMessageTooLargeException(this.length, {required this.sent});

  /// The length of the message (its length field).
  final int length;

  /// True for a request of this client, false for an answer of the agent.
  final bool sent;

  @override
  String get message => sent
      ? 'A request of $length bytes is larger than the SSH agent protocol '
          'allows ($sshAgentMaxMessageLength); it was not sent.'
      : 'The SSH agent sent an answer of $length bytes, larger than '
          '$sshAgentMaxMessageLength.';
}

/// The agent answered with a message type that does not answer the
/// request.
final class SshAgentUnexpectedMessageException extends SshAgentException {
  const SshAgentUnexpectedMessageException(this.messageType);

  final int messageType;

  @override
  String get message =>
      'The SSH agent answered with message type $messageType, which does '
      'not answer the request.';
}

/// The agent did not answer within [timeout].
final class SshAgentTimeoutException extends SshAgentException {
  const SshAgentTimeoutException(this.timeout);

  final Duration timeout;

  @override
  String get message =>
      'The SSH agent did not answer within ${_describe(timeout)}.';
}

/// The agent does not hold a key with the fingerprint [fingerprint].
final class SshAgentKeyNotFoundException extends SshAgentException {
  const SshAgentKeyNotFoundException(this.fingerprint);

  final String fingerprint;

  @override
  String get message => 'The SSH agent does not hold the key $fingerprint.';
}

/// The agent signed with another algorithm than the identity names: an
/// agent that ignores the flag of an RSA sign request, for example.
final class SshAgentWrongAlgorithmException extends SshAgentException {
  const SshAgentWrongAlgorithmException(this.fingerprint,
      {required this.expected, required this.actual});

  /// The key that signed.
  final String fingerprint;

  /// The algorithm of the identity.
  final String expected;

  /// The algorithm of the signature the agent returned.
  final String actual;

  @override
  String get message => 'The SSH agent signed with $actual, not $expected, '
      'for the key $fingerprint.';
}

String _describe(Duration duration) => duration.inMilliseconds % 1000 == 0
    ? '${duration.inSeconds} s'
    : '${duration.inMilliseconds} ms';

/// The fingerprint of the public key [keyBlob] in the form that
/// `ssh-add -l` prints: `SHA256:` and the base64 of the SHA-256 of the
/// blob, without `=` padding.
String sshKeyFingerprint(Uint8List keyBlob) =>
    'SHA256:${base64.encode(sha256.convert(keyBlob).bytes).replaceAll('=', '')}';

/// A key that the agent holds, as it listed it.
final class SshAgentIdentity {
  /// Throws an [SshAgentCutMessageException] when [keyBlob] does not start
  /// with a key type.
  SshAgentIdentity(this.keyBlob, this.comment)
      : keyType = _keyTypeOf(keyBlob),
        fingerprint = sshKeyFingerprint(keyBlob);

  /// The public key in SSH wire format, as the agent listed it.
  final Uint8List keyBlob;

  /// The comment the agent gave the key.
  final String comment;

  /// The key type, the first string of [keyBlob]: `ssh-rsa`,
  /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, ...
  final String keyType;

  /// The SHA-256 fingerprint of [keyBlob] ([sshKeyFingerprint]).
  final String fingerprint;

  /// The OpenSSH public key line `<type> <base64 blob>`, without a comment.
  String get publicKeyLine => '$keyType ${base64.encode(keyBlob)}';

  static String _keyTypeOf(Uint8List keyBlob) =>
      latin1.decode(_Reader(keyBlob).readString());
}

/// A client of the SSH agent at [socketPath].
///
/// Each request is one short connection: connect, send the request, read
/// one full answer, close. Nothing is kept between two requests, so a key
/// that the agent removed is gone for the next request.
final class SshAgentClient {
  SshAgentClient(this.socketPath, {this.timeout = sshAgentDefaultTimeout});

  /// The Unix-domain socket of the agent (`SSH_AUTH_SOCK`).
  final String socketPath;

  /// The longest time one request may take, from the connect to the end of
  /// the answer.
  final Duration timeout;

  /// The keys that the agent holds (`SSH_AGENTC_REQUEST_IDENTITIES`).
  Future<List<SshAgentIdentity>> listIdentities() async {
    final reader = _Reader(await _request(
        Uint8List.fromList([SshAgentMessage.requestIdentities])));
    final type = reader.readByte();
    if (type == SshAgentMessage.failure) {
      throw const SshAgentRefusedException();
    }
    if (type != SshAgentMessage.identitiesAnswer) {
      throw SshAgentUnexpectedMessageException(type);
    }
    final count = reader.readUint32();
    final identities = <SshAgentIdentity>[];
    for (var i = 0; i < count; i++) {
      final blob = Uint8List.fromList(reader.readString());
      final comment = utf8.decode(reader.readString(), allowMalformed: true);
      identities.add(SshAgentIdentity(blob, comment));
    }
    return identities;
  }

  /// The key of the agent whose fingerprint ([SshAgentIdentity.fingerprint])
  /// is [fingerprint], compared exactly. One list request.
  ///
  /// Throws an [SshAgentKeyNotFoundException] when the agent does not hold
  /// it.
  Future<SshAgentIdentity> findIdentity(String fingerprint) async {
    for (final identity in await listIdentities()) {
      if (identity.fingerprint == fingerprint) return identity;
    }
    throw SshAgentKeyNotFoundException(fingerprint);
  }

  /// Asks the agent to sign [data] with the key [keyBlob]
  /// (`SSH_AGENTC_SIGN_REQUEST`).
  ///
  /// [flags] selects the hash of an RSA signature
  /// ([SshAgentSignFlags.rsaSha256], [SshAgentSignFlags.rsaSha512]); none
  /// for other keys. Returns the signature as the agent sent it: an SSH
  /// signature blob, the algorithm name and the signature bytes, each an
  /// SSH string.
  ///
  /// Throws an [SshAgentRefusedException] with the fingerprint of the key
  /// when the agent answers `SSH_AGENT_FAILURE`.
  Future<Uint8List> sign(Uint8List keyBlob, Uint8List data,
      {int flags = SshAgentSignFlags.none}) async {
    final request = BytesBuilder(copy: false)
      ..addByte(SshAgentMessage.signRequest)
      ..add(_string(keyBlob))
      ..add(_string(data))
      ..add(_uint32(flags));
    final reader = _Reader(await _request(request.takeBytes()));
    final type = reader.readByte();
    if (type == SshAgentMessage.failure) {
      throw SshAgentRefusedException(fingerprint: sshKeyFingerprint(keyBlob));
    }
    if (type != SshAgentMessage.signResponse) {
      throw SshAgentUnexpectedMessageException(type);
    }
    return Uint8List.fromList(reader.readString());
  }

  /// Sends [message] (type byte and body) on a new connection and returns
  /// the answer (type byte and body).
  Future<Uint8List> _request(Uint8List message) async {
    if (message.length > sshAgentMaxMessageLength) {
      throw SshAgentMessageTooLargeException(message.length, sent: true);
    }
    final clock = Stopwatch()..start();
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: timeout,
      );
    } on SocketException {
      // Its text holds the path: not passed on.
      throw const SshAgentUnreachableException();
    } on ArgumentError {
      throw const SshAgentUnreachableException();
    }
    // A write error also ends the answer stream; it is reported there.
    socket.done.ignore();
    try {
      final answer = _readAnswer(socket);
      socket
        ..add(_uint32(message.length))
        ..add(message);
      final left = timeout - clock.elapsed;
      return await answer.timeout(left.isNegative ? Duration.zero : left,
          onTimeout: () => throw SshAgentTimeoutException(timeout));
    } finally {
      socket.destroy();
    }
  }
}

/// The algorithm name of an RSA identity of the agent; its sign requests set
/// [SshAgentSignFlags.rsaSha512]. (A key file of dartssh2 uses
/// `rsa-sha2-256`.)
const sshAgentRsaAlgorithm = 'rsa-sha2-512';

/// A dartssh2 identity for the key of the agent at [socketPath] whose
/// SHA-256 fingerprint is [fingerprint], in the form that `ssh-add -l`
/// prints, compared exactly.
///
/// Lists the keys of the agent once ([SshAgentClient.findIdentity]); an
/// agent that does not hold the key gives an [SshAgentKeyNotFoundException]
/// and no identity, so no other key is tried. Call it for each login:
/// nothing of the agent is kept between two logins.
///
/// The identity (design §6.1, §12):
/// - The public key is the blob the agent listed ([SSHRawHostKey]).
/// - Each signature is a new sign request on a new connection, so a key that
///   the agent lost after the listing gives an [SshAgentRefusedException].
/// - RSA (`ssh-rsa` blob): the identity names [sshAgentRsaAlgorithm] and the
///   request sets [SshAgentSignFlags.rsaSha512]. dartssh2 sends
///   [SSHIdentity.type] as the algorithm of the `publickey` request, as it
///   is, and does not compare it with the signature; the server does.
/// - Ed25519 and ECDSA: the algorithm is the key type, no flag.
/// - The agent returns an SSH signature blob (algorithm name and signature
///   bytes). It is passed on unchanged as an [SSHRawSignature], after its
///   algorithm is checked ([SshAgentWrongAlgorithmException]).
/// - [SSHIdentity.shouldProbe] is set: the server is asked first whether it
///   accepts the key, so the agent signs only for a key the server takes.
///
/// A signer that throws ends the login: dartssh2 closes the connection with
/// an `SSHInternalError` that wraps the exception, and tries no other
/// identity.
Future<SSHIdentity> agentIdentityFor(String socketPath, String fingerprint,
    {Duration timeout = sshAgentDefaultTimeout}) async {
  final client = SshAgentClient(socketPath, timeout: timeout);
  final key = await client.findIdentity(fingerprint);
  final isRsa = key.keyType == 'ssh-rsa';
  final algorithm = isRsa ? sshAgentRsaAlgorithm : key.keyType;
  final flags = isRsa ? SshAgentSignFlags.rsaSha512 : SshAgentSignFlags.none;
  return SSHIdentity.custom(
    type: algorithm,
    publicKey: SSHRawHostKey(key.keyBlob),
    comment: key.comment,
    shouldProbe: true,
    signer: (data) async {
      final signature = await client.sign(key.keyBlob, data, flags: flags);
      final signedWith = latin1.decode(_Reader(signature).readString());
      if (signedWith != algorithm) {
        throw SshAgentWrongAlgorithmException(key.fingerprint,
            expected: algorithm, actual: signedWith);
      }
      return SSHRawSignature(signature);
    },
  );
}

/// The first full answer on [socket], without its length field. A length
/// over [sshAgentMaxMessageLength] is refused as soon as it is read.
Future<Uint8List> _readAnswer(Stream<Uint8List> socket) {
  final answer = Completer<Uint8List>();
  final received = BytesBuilder(copy: false);
  late final StreamSubscription<Uint8List> subscription;

  void finish(Object result) {
    if (answer.isCompleted) return;
    if (result is Uint8List) {
      answer.complete(result);
    } else {
      answer.completeError(result);
    }
    unawaited(subscription.cancel());
  }

  subscription = socket.listen(
    (chunk) {
      received.add(chunk);
      if (received.length < 4) return;
      final bytes = received.toBytes();
      final length = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      if (length > sshAgentMaxMessageLength) {
        finish(SshAgentMessageTooLargeException(length, sent: false));
      } else if (length == 0) {
        // Not even a type byte.
        finish(const SshAgentCutMessageException(closed: false));
      } else if (bytes.length >= 4 + length) {
        finish(Uint8List.sublistView(bytes, 4, 4 + length));
      }
    },
    onError: (Object _) => finish(const SshAgentCutMessageException()),
    onDone: () => finish(const SshAgentCutMessageException()),
  );
  return answer.future;
}

Uint8List _uint32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value);
  return bytes;
}

Uint8List _string(Uint8List value) {
  final bytes = Uint8List(4 + value.length);
  ByteData.sublistView(bytes).setUint32(0, value.length);
  bytes.setRange(4, bytes.length, value);
  return bytes;
}

/// Reads the fields of an agent message; a field past the end throws an
/// [SshAgentCutMessageException].
class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  int readByte() {
    _need(1);
    return _bytes[_offset++];
  }

  int readUint32() {
    _need(4);
    final value =
        ByteData.sublistView(_bytes, _offset, _offset + 4).getUint32(0);
    _offset += 4;
    return value;
  }

  Uint8List readString() {
    final length = readUint32();
    _need(length);
    final value = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }

  void _need(int count) {
    if (count > _bytes.length - _offset) {
      throw const SshAgentCutMessageException(closed: false);
    }
  }
}
