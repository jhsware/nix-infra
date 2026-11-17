import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dotenv/dotenv.dart';
import 'package:path/path.dart' as path;

import 'package:nix_infra/types.dart';

// SSH_KEY_PATH: one private key file for every machine of a CLI command, and
// the public key of a private key file (docs/analysis/
// 2026-11-17-ssh-key-resolution-external-identities.md §5.2).
//
// No function of this file reads the key into a message: an error names the
// path of the file, never its content.

/// The private key file of `SSH_KEY_PATH` in [env], as an absolute,
/// normalized path, or null when the variable is not set or is empty (after
/// trimming).
///
/// - A leading `~/` is the home directory ([homeDir], default `HOME` of the
///   process environment); a value in `.env` is not expanded by a shell.
/// - An absolute path is used as it is (normalized).
/// - Any other path is relative to [workingDir] (the project folder), the
///   rule of `ssh_key` in servers.yaml.
///
/// Throws an [Exception] when the file does not exist, before any
/// connection is made. A key of a sysops vault is deleted when the vault is
/// locked, so the message says what to do then.
String? resolveSshKeyPath(DotEnv env, Directory workingDir,
    {String? homeDir}) {
  final value = env['SSH_KEY_PATH']?.trim();
  if (value == null || value.isEmpty) return null;

  final String keyPath;
  if (value.startsWith('~/')) {
    final home = homeDir ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw Exception('SSH_KEY_PATH starts with ~/ but HOME is not set: '
          '$value. Use an absolute path.');
    }
    keyPath = path.normalize(path.join(home, value.substring(2)));
  } else if (path.isAbsolute(value)) {
    keyPath = path.normalize(value);
  } else {
    keyPath = path.normalize(path.join(workingDir.absolute.path, value));
  }

  if (!File(keyPath).existsSync()) {
    throw Exception('SSH_KEY_PATH names a file that does not exist: '
        '$keyPath. If a sysops terminal set it: unlock the vault and open a '
        'new terminal.');
  }
  return keyPath;
}

/// The OpenSSH public key line `<type> <base64 blob>` of the private key
/// [pem], without a comment: the line of `ssh-keygen -y -f <file>` without
/// its comment.
///
/// The type is the first string of the public key blob. `SSHKeyPair.type`
/// is not used: for an RSA key dartssh2 returns the signature algorithm
/// there, not `ssh-rsa`.
///
/// Throws an [Exception] for a key with a passphrase, for a text that is
/// not one private key that dartssh2 can read, and when no public key can
/// be derived. No message contains the key text.
String publicKeyLineFromPrivateKey(String pem) {
  try {
    return _publicKeyLine(pem);
  } on _SshKeyError catch (e) {
    throw Exception('The SSH key ${e.reason}');
  }
}

/// The public key of the private key file [privateKeyPath]: the trimmed
/// content of `<privateKeyPath>.pub` when that file exists, else the line
/// derived from the private key ([publicKeyLineFromPrivateKey]).
Future<String> publicKeyOfKeyFile(String privateKeyPath) async {
  final pubFile = File('$privateKeyPath.pub');
  if (await pubFile.exists()) {
    return (await pubFile.readAsString()).trim();
  }

  final pem = (await File(privateKeyPath).readAsString()).trim();
  try {
    return _publicKeyLine(pem);
  } on _SshKeyError catch (e) {
    throw Exception('Cannot derive the public key from $privateKeyPath, and '
        '$privateKeyPath.pub does not exist: the SSH key ${e.reason}');
  }
}

/// The public key of [node]: the one written as root's authorized key
/// (`[%%sshKey%%]` of configuration.nix).
///
/// The private key file is [ClusterNode.getEffectiveSshKeyPath]; see
/// [publicKeyOfKeyFile]. For a project with `ssh/<name>` and
/// `ssh/<name>.pub` the result is the content of `ssh/<name>.pub`, as
/// before SSH_KEY_PATH.
Future<String> publicKeyOf(Directory workingDir, ClusterNode node) {
  return publicKeyOfKeyFile(node.getEffectiveSshKeyPath(workingDir.path));
}

/// Why a key cannot be used, as the end of a sentence that starts with
/// "The SSH key". Never holds key text.
class _SshKeyError implements Exception {
  final String reason;
  const _SshKeyError(this.reason);
}

String _publicKeyLine(String pem) {
  const unreadable = 'is not a private key that nix-infra can read';
  final bool encrypted;
  try {
    encrypted = SSHKeyPair.isEncryptedPem(pem);
  } catch (_) {
    // The error of the parser can quote bytes of the key: not passed on.
    throw const _SshKeyError(unreadable);
  }
  if (encrypted) {
    throw const _SshKeyError('has a passphrase; nix-infra cannot use it');
  }

  final List<SSHKeyPair> pairs;
  try {
    pairs = SSHKeyPair.fromPem(pem);
  } catch (_) {
    throw const _SshKeyError(unreadable);
  }
  if (pairs.length != 1) {
    throw _SshKeyError('holds ${pairs.length} private keys, not one');
  }

  final Uint8List blob;
  try {
    blob = pairs.single.toPublicKey().encode();
  } catch (_) {
    throw const _SshKeyError('gives no public key');
  }
  final type = _firstSshString(blob);
  if (type == null || type.isEmpty) {
    throw const _SshKeyError('gives no public key');
  }
  return '$type ${base64.encode(blob)}';
}

/// The first SSH string of [blob] (a 4-byte big-endian length and the
/// bytes): the key type of a public key blob. Null when [blob] is too short.
String? _firstSshString(Uint8List blob) {
  if (blob.length < 4) return null;
  final length = ByteData.sublistView(blob, 0, 4).getUint32(0);
  if (length > blob.length - 4) return null;
  return latin1.decode(blob.sublist(4, 4 + length));
}
