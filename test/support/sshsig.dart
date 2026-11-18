import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'fake_ssh_agent.dart' show sshString, uint32;
import 'ssh_test_env.dart' show findSshTool;

// An SSH signature in the format of `ssh-keygen -Y sign` (OpenSSH
// PROTOCOL.sshsig), so that `ssh-keygen -Y check-novalidate` checks a
// signature that an agent made against the public key in the signature
// file. dartssh2 4.1 exports no verifier for a public key (its
// src/hostkey/ files are not exported), so OpenSSH checks instead.

const _magic = 'SSHSIG';

/// The bytes that a key signs for an SSH signature of [message] in
/// [namespace], with the hash SHA-512.
Uint8List sshsigSignedData(String namespace, List<int> message) =>
    Uint8List.fromList([
      ...ascii.encode(_magic),
      ...sshString(utf8.encode(namespace)),
      ...sshString(const []), // reserved
      ...sshString(ascii.encode('sha512')),
      ...sshString(sha512.convert(message).bytes),
    ]);

/// The armored SSH signature (`-----BEGIN SSH SIGNATURE-----`) of the key
/// [publicKeyBlob] whose [signature] (an SSH signature blob) signs
/// [sshsigSignedData] of [namespace].
String sshsigArmor(
  List<int> publicKeyBlob,
  String namespace,
  List<int> signature,
) {
  final encoded = base64.encode([
    ...ascii.encode(_magic),
    ...uint32(1), // version
    ...sshString(publicKeyBlob),
    ...sshString(utf8.encode(namespace)),
    ...sshString(const []), // reserved
    ...sshString(ascii.encode('sha512')),
    ...sshString(signature),
  ]);
  return [
    '-----BEGIN SSH SIGNATURE-----',
    for (var i = 0; i < encoded.length; i += 70)
      encoded.substring(i, min(i + 70, encoded.length)),
    '-----END SSH SIGNATURE-----',
    '',
  ].join('\n');
}

/// Runs `ssh-keygen -Y check-novalidate` on the signature file
/// [signatureFile] for [message] in [namespace]. Exit code 0: the signature
/// is good for the public key in the file.
Future<ProcessResult> sshsigCheck(
  String signatureFile,
  String namespace,
  List<int> message,
) async {
  final process = await Process.start(findSshTool('ssh-keygen')!, [
    '-Y', 'check-novalidate', '-n', namespace, '-s', signatureFile, //
  ]);
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  process.stdin.add(message);
  await process.stdin.close();
  return ProcessResult(
    process.pid,
    await process.exitCode,
    await stdout,
    await stderr,
  );
}
