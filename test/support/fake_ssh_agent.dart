import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

// A fake SSH agent on a Unix-domain socket, for the tests of
// lib/ssh_agent.dart that always run (docs/design/ssh_agent_keys.md §10).
// It reads one request per connection and writes the bytes that
// [FakeSshAgent.answer] returns as they are, not framed, so a test can send
// a cut message or a length that is too large. The message helpers below
// build the bytes of RFC 9987.

/// What the fake agent writes for one request.
class FakeAnswer {
  const FakeAnswer(this.bytes, {this.close = true});

  /// The raw bytes to write, the length field included.
  final List<int> bytes;

  /// Whether the agent closes its side of the connection after [bytes].
  final bool close;
}

/// A fake agent in a temporary folder of the test.
class FakeSshAgent {
  FakeSshAgent._(this.dir, this.socketPath, this._server) {
    _server.listen(_serve);
  }

  /// The temporary folder that holds the socket.
  final Directory dir;

  /// The socket of the agent.
  final String socketPath;

  final ServerSocket _server;
  final _sockets = <Socket>[];

  /// The connections the agent accepted.
  int connections = 0;

  /// The connections that the client closed.
  int closedByClient = 0;

  /// Each request in order: the type byte and the body, without the
  /// length field.
  final requests = <Uint8List>[];

  /// The answer to a request. Default: `SSH_AGENT_FAILURE`.
  FakeAnswer Function(Uint8List request) answer =
      (_) => FakeAnswer(frame([5]));

  /// Starts a fake agent in a new temporary folder. The folder is under
  /// `/tmp` when it exists: a Unix socket path has at most 104 bytes on
  /// macOS.
  static Future<FakeSshAgent> start() async {
    final tmp = Directory('/tmp');
    final dir = (tmp.existsSync() ? tmp : Directory.systemTemp)
        .createTempSync('nix_infra_agent_');
    final socketPath = path.join(dir.path, 'agent.sock');
    final server = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    return FakeSshAgent._(dir, socketPath, server);
  }

  /// Waits until [done] is true, at most [timeout].
  Future<void> waitUntil(bool Function() done,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('The fake agent waited $timeout in vain.');
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Closes every connection and the socket, and deletes [dir].
  Future<void> stop() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the system to clean up.
    }
  }

  void _serve(Socket socket) {
    connections++;
    _sockets.add(socket);
    socket.done.ignore();
    final received = BytesBuilder();
    var answered = false;
    socket.listen(
      (chunk) {
        if (answered) return;
        received.add(chunk);
        final bytes = received.toBytes();
        if (bytes.length < 4) return;
        final length = ByteData.sublistView(bytes, 0, 4).getUint32(0);
        if (bytes.length < 4 + length) return;
        answered = true;
        final request = Uint8List.fromList(bytes.sublist(4, 4 + length));
        requests.add(request);
        final reply = answer(request);
        socket.add(reply.bytes);
        if (reply.close) socket.close().ignore();
      },
      onError: (Object _) {},
      onDone: () {
        closedByClient++;
        socket.destroy();
      },
    );
  }
}

/// A message with its length field: uint32 (big-endian) and [message].
Uint8List frame(List<int> message) =>
    Uint8List.fromList([...uint32(message.length), ...message]);

/// A uint32, big-endian.
Uint8List uint32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value);
  return bytes;
}

/// An SSH string: its length as a uint32 and [value].
Uint8List sshString(List<int> value) =>
    Uint8List.fromList([...uint32(value.length), ...value]);

/// A public key blob of [keyType] with random key bytes. The client reads
/// only the key type.
Uint8List fakeKeyBlob(String keyType, {int keyBytes = 32}) {
  final random = Random.secure();
  return Uint8List.fromList([
    ...sshString(keyType.codeUnits),
    ...sshString([for (var i = 0; i < keyBytes; i++) random.nextInt(256)]),
  ]);
}

/// A signature blob of [algorithm]: the algorithm name and [bytes].
Uint8List fakeSignatureBlob(String algorithm, List<int> bytes) =>
    Uint8List.fromList([...sshString(algorithm.codeUnits), ...sshString(bytes)]);
