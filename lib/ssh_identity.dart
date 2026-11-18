import 'dart:io';

import 'package:dartssh2/dartssh2.dart' show SSHIdentity, SSHKeyPair;
import 'package:path/path.dart' as p;

import 'package:nix_infra/helpers.dart' show getSshKeyAsPemFromNode;
import 'package:nix_infra/ssh_agent.dart';
import 'package:nix_infra/ssh_key_errors.dart';
import 'package:nix_infra/ssh_key_path.dart' show publicKeyOfKeyFile;
import 'package:nix_infra/types.dart';

// One place for "the key of a machine" (docs/design/ssh_agent_keys.md
// §6.2). These three functions are the only code that reads a key for a
// login ([identitiesOf]), reads the public key of a machine ([publicKeyOf])
// or builds an `ssh` command line for a machine ([sshCommand]). Each one
// follows the key source of the machine ([ClusterNode.keySource]):
//
// - [KeyFileSource]: the private key file, as before.
// - [AgentKeySource]: the key of the ssh-agent with the fingerprint of the
//   machine, and only that key. The agent is asked at each call; nothing
//   of the agent is kept.
// - [UnavailableKeySource], [KeyMapUnreadableSource]: a [NodeKeyException];
//   no other key is tried.
//
// Every error about the key is a [NodeKeyException], whose text holds no
// path (design §7).

/// The identities that log in to [node].
///
/// - Key file: the key pairs of the private key file
///   ([ClusterNode.getEffectiveSshKeyPath]), as before. A file that is
///   missing, cannot be read, has a passphrase or is not a private key
///   gives a [NodeKeyFileException] (its text names no path and no byte of
///   the key).
/// - Agent key: one identity, the key of the agent with the fingerprint of
///   the machine (`agentIdentityFor` of lib/ssh_agent.dart). The agent is
///   asked now; call this function for each login.
/// - Not available: a [NodeKeyException].
///
/// [agentSocket], when given, is used in place of the socket of the key
/// source; [agentTimeout] bounds each request to the agent.
Future<List<SSHIdentity>> identitiesOf(Directory workingDir, ClusterNode node,
    {String? agentSocket, Duration? agentTimeout}) async {
  final source = node.keySource;
  if (source is KeyFileSource) return _keyFileIdentities(workingDir, node);
  final (fingerprint, socket) = _agentKeyOf(node, agentSocket);
  try {
    return [
      await agentIdentityFor(socket, fingerprint,
          timeout: agentTimeout ?? sshAgentDefaultTimeout)
    ];
  } on SshAgentException catch (e) {
    throw nodeKeyErrorOfAgent(node, e);
  }
}

/// The public key of [node], the one written as root's authorized key
/// (`[%%sshKey%%]` of configuration.nix): `<type> <base64>`.
///
/// - Key file: `<private key file>.pub` when it exists, else the line
///   derived from the private key (`publicKeyOfKeyFile` of
///   lib/ssh_key_path.dart). For a project with `ssh/<name>` and
///   `ssh/<name>.pub` the result is the content of `ssh/<name>.pub`, as
///   before. Its errors name the path: only the CLI uses it.
/// - Agent key: the public key that the agent lists for the fingerprint of
///   the machine, without a comment.
/// - Not available: a [NodeKeyException].
Future<String> publicKeyOf(Directory workingDir, ClusterNode node,
    {String? agentSocket, Duration? agentTimeout}) async {
  if (node.keySource is KeyFileSource) {
    return publicKeyOfKeyFile(node.getEffectiveSshKeyPath(workingDir.path));
  }
  final (fingerprint, socket) = _agentKeyOf(node, agentSocket);
  try {
    final client = SshAgentClient(socket,
        timeout: agentTimeout ?? sshAgentDefaultTimeout);
    return (await client.findIdentity(fingerprint)).publicKeyLine;
  } on SshAgentException catch (e) {
    throw nodeKeyErrorOfAgent(node, e);
  }
}

/// An `ssh` command line for a machine ([sshCommand]); [dispose] it when the
/// command has run.
final class SshCommand {
  SshCommand._(this.command, this._tempDir);

  /// `ssh` with its options and `root@<ip>`, without a remote command. The
  /// caller appends the remote command.
  final String command;

  /// The folder of the temporary public key file, for an agent key.
  final Directory? _tempDir;

  /// The temporary public key file that [command] names with `-i`, for an
  /// agent key; null for a key file.
  String? get publicKeyFile =>
      _tempDir == null ? null : p.join(_tempDir.path, _publicKeyFileName);

  /// Deletes the temporary public key file, if there is one.
  Future<void> dispose() async {
    final dir = _tempDir;
    if (dir != null && await dir.exists()) await dir.delete(recursive: true);
  }
}

const _publicKeyFileName = 'key.pub';

/// The `ssh` command line for [node], up to `root@<ip>`.
///
/// - Key file:
///   `ssh -i "<private key file>" -o StrictHostKeyChecking=no root@<ip>`,
///   the string that nix-infra always built.
/// - Agent key:
///   `ssh -o "IdentityAgent=<socket>" -o IdentitiesOnly=yes -o ForwardAgent=no -i "<public key file>" -o StrictHostKeyChecking=no root@<ip>`.
///   The public key of the machine is written to a temporary file (mode
///   600) in a new temporary folder, so `ssh` offers that one key of the
///   agent. The agent is never forwarded. [SshCommand.dispose] deletes the
///   file; prefer [withSshCommand], which always does.
/// - Not available: a [NodeKeyException], and no file is written.
Future<SshCommand> sshCommand(Directory workingDir, ClusterNode node,
    {String? agentSocket}) async {
  final target = '-o StrictHostKeyChecking=no root@${node.ipAddr}';
  if (node.keySource is KeyFileSource) {
    final keyFile = node.getEffectiveSshKeyPath(workingDir.path);
    return SshCommand._('ssh -i "$keyFile" $target', null);
  }
  final (_, socket) = _agentKeyOf(node, agentSocket);
  final publicKey = await publicKeyOf(workingDir, node, agentSocket: socket);
  final dir = await Directory.systemTemp.createTemp('nix-infra-ssh-');
  try {
    final file = File(p.join(dir.path, _publicKeyFileName));
    await file.create(exclusive: true);
    await _chmod600(file.path);
    await file.writeAsString('$publicKey\n', flush: true);
    return SshCommand._(
        'ssh -o "IdentityAgent=$socket" -o IdentitiesOnly=yes '
        '-o ForwardAgent=no -i "${file.path}" $target',
        dir);
  } catch (_) {
    await dir.delete(recursive: true);
    rethrow;
  }
}

/// Runs [run] with the `ssh` command line of [node] ([sshCommand]) and
/// deletes its temporary public key file afterwards, also when [run]
/// throws.
Future<T> withSshCommand<T>(Directory workingDir, ClusterNode node,
    Future<T> Function(String sshCommand) run,
    {String? agentSocket}) async {
  final ssh = await sshCommand(workingDir, node, agentSocket: agentSocket);
  try {
    return await run(ssh.command);
  } finally {
    await ssh.dispose();
  }
}

/// The fingerprint and the agent socket of [node], which has an agent key;
/// [agentSocket] wins over the socket of the key source. Throws the
/// [NodeKeyException] of a machine whose key is not available, or of a
/// missing socket.
(String, String) _agentKeyOf(ClusterNode node, String? agentSocket) =>
    switch (node.keySource) {
      AgentKeySource(:final fingerprint, agentSocket: final sourceSocket) => (
          fingerprint,
          agentSocket ??
              sourceSocket ??
              (throw NodeKeyNoAgentSocketException(node.name))
        ),
      UnavailableKeySource(:final reason) =>
        throw NodeKeyUnavailableException(node.name, reason),
      KeyMapUnreadableSource(:final detail) =>
        throw NodeKeyMapUnreadableException(node.name, detail),
      KeyFileSource() => throw StateError('${node.name} uses a key file'),
    };

/// The key pairs of the private key file of [node].
Future<List<SSHIdentity>> _keyFileIdentities(
    Directory workingDir, ClusterNode node) async {
  final keyPath = node.getEffectiveSshKeyPath(workingDir.path);
  final String pem;
  try {
    pem = await getSshKeyAsPemFromNode(workingDir, node);
  } on FileSystemException {
    // Its text holds the path: not passed on.
    throw NodeKeyFileException(
        node.name,
        keyPath,
        File(keyPath).existsSync()
            ? NodeKeyFileProblem.unreadable
            : NodeKeyFileProblem.missing);
  }
  try {
    return [...SSHKeyPair.fromPem(pem)];
  } catch (_) {
    // The error of the parser can quote bytes of the key: not passed on.
    throw NodeKeyFileException(
        node.name,
        keyPath,
        _isEncryptedPem(pem)
            ? NodeKeyFileProblem.passphrase
            : NodeKeyFileProblem.invalid);
  }
}

bool _isEncryptedPem(String pem) {
  try {
    return SSHKeyPair.isEncryptedPem(pem);
  } catch (_) {
    return false;
  }
}

Future<void> _chmod600(String path) async {
  final result = await Process.run('chmod', ['600', path]);
  if (result.exitCode != 0) {
    throw FileSystemException('chmod 600 failed: ${result.stderr}', path);
  }
}
