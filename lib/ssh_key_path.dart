import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

// The public key of a private key file: `<file>.pub` when it exists, else
// derived from the private key (docs/analysis/
// 2026-11-17-ssh-key-resolution-external-identities.md §5.2). The public key
// of a machine is `publicKeyOf` of lib/ssh_identity.dart.
//
// No function of this file reads the key into a message: an error names the
// path of the file, never its content.

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
///
/// The public key of a machine is `publicKeyOf` of lib/ssh_identity.dart,
/// which uses this function for a machine with a key file.
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
