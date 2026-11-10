import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/secret_codec.dart';
import 'package:nix_infra/types.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:process_run/shell.dart';

// Secrets are stored in [project]/secrets/<name> (see lib/secret_codec.dart
// for the file formats), encrypted with the files key (SECRETS_PASS).
//
// When deploying apps on a node, the secrets the node configuration refers
// to are decrypted locally and encrypted again on the node with
// `systemd-creds encrypt - /root/secrets/<name>`. Secrets in /root/secrets
// that are no longer needed are removed.

/// Thrown by [readSecret] when `secrets/<name>` does not exist.
class SecretNotFound implements Exception {
  const SecretNotFound(this.name);

  final String name;

  @override
  String toString() => 'SecretNotFound: Secret "$name" not found';
}

/// Thrown by [saveSecret] when `secrets/<name>` exists and `overwrite` is
/// false.
class SecretExists implements Exception {
  const SecretExists(this.name);

  final String name;

  @override
  String toString() => 'SecretExists: Secret "$name" exists';
}

/// Where secret warnings are written. Tests can replace it to capture the
/// output.
void Function(String message) secretWarningSink = stderrLog;

bool _legacyWarningShown = false;

/// Lets the next legacy base64 read print the warning again (for tests).
void resetLegacySecretWarning() {
  _legacyWarningShown = false;
}

final _random = Random.secure();

Directory _secretsDir(Directory workingDir) =>
    Directory('${workingDir.path}/secrets');

/// Refuses names that would leave the secrets folder or that are reserved
/// (dot files, such as the temporary files of [saveSecret]).
void _checkSecretName(String name) {
  if (name.isEmpty || name.contains('/') || name.startsWith('.')) {
    throw ArgumentError.value(name, 'name',
        'must not be empty, contain "/" or start with "."');
  }
}

/// True when `secrets/<name>` exists.
bool secretExists(Directory workingDir, String name) {
  _checkSecretName(name);
  return File('${_secretsDir(workingDir).path}/$name').existsSync();
}

/// The `kind` stored in a v2 file: [kSecretKindGithubNetrc] when [value] is
/// one netrc entry
/// `machine api.github.com login x-access-token password <token>`,
/// else [kSecretKindText].
String detectSecretKind(String value) {
  final tokens =
      value.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (tokens.length != 6 || tokens.first != 'machine') return kSecretKindText;
  final fields = <String, String>{};
  for (var i = 0; i < tokens.length; i += 2) {
    final key = tokens[i];
    if (!const {'machine', 'login', 'password'}.contains(key) ||
        fields.containsKey(key)) {
      return kSecretKindText;
    }
    fields[key] = tokens[i + 1];
  }
  return fields['machine'] == 'api.github.com' &&
          fields['login'] == 'x-access-token'
      ? kSecretKindGithubNetrc
      : kSecretKindText;
}

Future<void> _chmod(String mode, String path) async {
  // Only the mode and the path are passed to the child process, never a
  // secret value.
  final res = await Process.run('chmod', [mode, path]);
  if (res.exitCode != 0) {
    throw FileSystemException('chmod $mode failed: ${res.stderr}', path);
  }
}

String _randomHex(int bytes) => List.generate(
        bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'))
    .join();

/// Encrypts [secret] with [secretsPassword] (the files key or a password)
/// and writes it as a `nix-infra-secret/v2` file to `secrets/<name>`.
///
/// The write is atomic: the file is written to `secrets/.tmp-<random>`
/// (mode 600), read back and decrypted to check it, then renamed onto
/// `secrets/<name>` and set to mode 400. The value is never written to disk
/// in plaintext and never passed to a child process.
///
/// Throws [SecretExists] when the secret exists and [overwrite] is false.
Future<void> saveSecret(Directory workingDir, String secretsPassword,
    String secretNamespace, String secret,
    {bool overwrite = false, bool debug = false}) async {
  _checkSecretName(secretNamespace);
  final secretsDir = _secretsDir(workingDir);

  if (!secretsDir.existsSync()) {
    echo('Create secrets dir');
    await secretsDir.create(recursive: true);
    await _chmod('700', secretsDir.path);
  }

  final target = File('${secretsDir.path}/$secretNamespace');
  if (!overwrite && target.existsSync()) {
    throw SecretExists(secretNamespace);
  }

  final encrypted = await encryptSecretV2(
    plaintext: secret,
    key: secretsPassword,
    kind: detectSecretKind(secret),
    created: DateTime.now().toUtc(),
  );

  final tmpFile = File('${secretsDir.path}/.tmp-${_randomHex(8)}');
  try {
    // Created empty and restricted before any content is written.
    await tmpFile.create(exclusive: true);
    await _chmod('600', tmpFile.path);
    final raf = await tmpFile.open(mode: FileMode.writeOnly);
    try {
      await raf.writeFrom(encrypted);
      await raf.flush();
    } finally {
      await raf.close();
    }

    final readBack = await tmpFile.readAsBytes();
    final check = await decryptSecret(readBack, key: secretsPassword);
    if (check.plaintext != secret) {
      throw FileSystemException(
          'Secret "$secretNamespace" did not read back correctly',
          tmpFile.path);
    }

    if (!overwrite && target.existsSync()) {
      throw SecretExists(secretNamespace);
    }
    await tmpFile.rename(target.path);
    await _chmod('400', target.path);
  } catch (_) {
    if (tmpFile.existsSync()) tmpFile.deleteSync();
    rethrow;
  }
}

/// The format label `nix-infra secrets list` prints for a file.
String secretFormatLabel(SecretFileFormat format) => switch (format) {
      SecretFileFormat.v2 => 'v2',
      SecretFileFormat.opensslSalted => 'openssl',
      SecretFileFormat.legacyBase64 => 'plain',
      SecretFileFormat.unknown => 'unknown',
    };

/// Formats [time] as UTC ISO 8601 with seconds, like the v2 `created` field.
String formatSecretTime(DateTime time) {
  final t = time.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
}

/// One line of `nix-infra secrets list`. No value and no key is read to
/// build it.
class SecretListRow {
  const SecretListRow({
    required this.name,
    required this.format,
    this.kind,
    this.created,
    this.modified,
    this.secretFormat,
  });

  final String name;

  /// `v2`, `openssl`, `plain`, `unknown` or `link`.
  final String format;

  /// The `kind` of a v2 file, `(bad header)` when the v2 header cannot be
  /// parsed, else null.
  final String? kind;

  /// The `created` time of a v2 file, else null.
  final DateTime? created;

  /// The modification time of a regular file; null for a symbolic link.
  final DateTime? modified;

  /// The detected format; null for a symbolic link.
  final SecretFileFormat? secretFormat;

  bool get isLink => secretFormat == null;
}

/// Builds the list row of one entry in the secrets folder.
///
/// [bytes] is the content of a regular file, or null when it could not be
/// read; [isLink] is true for a symbolic link (which is not followed). Only
/// the format is detected and the v2 header is parsed; nothing is decrypted.
SecretListRow buildSecretListRow(
  String name, {
  Uint8List? bytes,
  bool isLink = false,
  DateTime? modified,
}) {
  if (isLink) {
    return SecretListRow(name: name, format: 'link');
  }
  final format =
      bytes == null ? SecretFileFormat.unknown : detectSecretFormat(bytes);
  String? kind;
  DateTime? created;
  if (format == SecretFileFormat.v2) {
    try {
      final header = parseSecretV2Header(bytes!);
      kind = header.kind;
      created = header.created;
    } on SecretFormatUnknown {
      kind = '(bad header)';
    }
  }
  return SecretListRow(
    name: name,
    format: secretFormatLabel(format),
    kind: kind,
    created: created,
    modified: modified,
    secretFormat: format,
  );
}

/// The rows for every entry in `secrets/` whose name does not start with
/// `.`, sorted by name. Regular files are read (not decrypted); symbolic
/// links are listed as `link` and not followed; other entries (folders) are
/// left out. Returns an empty list when the folder does not exist.
List<SecretListRow> listSecretFiles(Directory workingDir) {
  final secretsDir = _secretsDir(workingDir);
  if (!secretsDir.existsSync()) return [];
  final rows = <SecretListRow>[];
  for (final entry in secretsDir.listSync(followLinks: false)) {
    final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (name.startsWith('.')) continue;
    if (entry is Link) {
      rows.add(buildSecretListRow(name, isLink: true));
      continue;
    }
    if (entry is! File) continue;
    Uint8List? bytes;
    DateTime? modified;
    try {
      modified = entry.lastModifiedSync();
      bytes = entry.readAsBytesSync();
    } on FileSystemException {
      bytes = null;
    }
    rows.add(buildSecretListRow(name, bytes: bytes, modified: modified));
  }
  rows.sort((a, b) => a.name.compareTo(b.name));
  return rows;
}

/// Formats [rows] as aligned columns NAME, FORMAT, KIND, CREATED, MODIFIED
/// with a header line. Empty cells are `-`.
List<String> formatSecretListRows(List<SecretListRow> rows) {
  final table = <List<String>>[
    ['NAME', 'FORMAT', 'KIND', 'CREATED', 'MODIFIED'],
    for (final row in rows)
      [
        row.name,
        row.format,
        row.kind ?? '-',
        row.created != null ? formatSecretTime(row.created!) : '-',
        row.modified != null ? formatSecretTime(row.modified!) : '-',
      ],
  ];
  final widths = List.filled(5, 0);
  for (final cells in table) {
    for (var i = 0; i < cells.length; i++) {
      widths[i] = max(widths[i], cells[i].length);
    }
  }
  return [
    for (final cells in table)
      [
        for (var i = 0; i < cells.length; i++)
          i == cells.length - 1 ? cells[i] : cells[i].padRight(widths[i]),
      ].join('  '),
  ];
}

/// Reads and decrypts `secrets/<name>` (v2, legacy OpenSSL or legacy
/// base64).
///
/// Throws [SecretNotFound] when the file does not exist, and passes through
/// [SecretDecryptFailed], [SecretKeyMismatch] and [SecretFormatUnknown].
Future<String> readSecret(
    Directory workingDir, String secretsPassword, String secretNamespace,
    {bool debug = false}) async {
  _checkSecretName(secretNamespace);
  final secretsDir = _secretsDir(workingDir);
  final secretFile = File('${secretsDir.path}/$secretNamespace');

  final Uint8List bytes;
  try {
    bytes = await secretFile.readAsBytes();
  } on PathNotFoundException {
    throw SecretNotFound(secretNamespace);
  }

  final result = await decryptSecret(bytes, key: secretsPassword);
  if (result.format == SecretFileFormat.legacyBase64) {
    _warnLegacySecrets(secretsDir);
  }

  // Earlier versions decrypted with `openssl enc -d` and returned the
  // process_run `outText` of it, which splits the output into lines and
  // joins them with '\n': CRLF and CR become LF and the last line break is
  // removed. Return exactly that value, so deployed secrets do not change.
  return const LineSplitter().convert(result.plaintext).join('\n');
}

/// Prints one warning per process that lists the legacy base64 (not
/// encrypted) files in [secretsDir]. Only names are printed, no values.
void _warnLegacySecrets(Directory secretsDir) {
  if (_legacyWarningShown) return;
  _legacyWarningShown = true;

  final names = <String>[];
  for (final entry in secretsDir.listSync()) {
    if (entry is! File) continue;
    final name = entry.uri.pathSegments.last;
    if (name.startsWith('.')) continue;
    try {
      if (detectSecretFormat(entry.readAsBytesSync()) ==
          SecretFileFormat.legacyBase64) {
        names.add(name);
      }
    } on FileSystemException {
      // Not readable: not listed.
    }
  }
  names.sort();
  secretWarningSink(
      'WARNING! These secret files are not encrypted, run `nix-infra secrets migrate`: '
      '${names.join(', ')}');
}

/// Loads a secret for deployment to [nodeName].
///
/// Returns null and prints a warning when the secret does not exist. Any
/// other error (wrong key, damaged file, unknown format) prints an error
/// without the value and is rethrown, so the deployment of the node stops.
Future<String?> loadSecretForDeploy(
    Directory workingDir, String secretsPwd, String secretName,
    {required String nodeName}) async {
  try {
    return await readSecret(workingDir, secretsPwd, secretName);
  } on SecretNotFound {
    echo(
        "WARNING! Secret '$secretName' not found in secrets directory, skipping deployment to $nodeName");
    echo(
        "  Add it with: nix-infra store-secret --secret=\"<value>\" --store-as-secret=\"$secretName\"");
    return null;
  } catch (err) {
    final reason = err is SecretCodecException ? err.message : '$err';
    echo("ERROR! Secret '$secretName' could not be read: $reason");
    rethrow;
  }
}

Future<void> deploySecretOnRemote(
  Directory workingDir,
  String secretName,
  String secret,
  ClusterNode node, {
  required SSHClient sshClient,
  bool debug = false,
}) async {
  final sshCmd =
      'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr}';

  final controller = StreamController<List<int>>();

  final shell = Shell(
    runInShell: true,
    verbose: debug,
    stdin: controller.stream,
  );

  controller.add(utf8.encode(secret));
  controller.close();

  await shell
      .run('$sshCmd "systemd-creds encrypt - /root/secrets/$secretName"');
}

Future<void> syncSecrets(
  Directory workingDir,
  Iterable<ClusterNode> cluster,
  ClusterNode node,
  List<String> expectedSecrets,
  SSHClient sshClient, {
  required String secretsPwd,
  bool debug = false,
  bool overlayNetwork = true,
}) async {
  // Create list of variable substitutions
  final substitutions = Map.fromEntries(
      cluster.map((node) => MapEntry('${node.name}.ipv4', node.ipAddr)));

  if (overlayNetwork) {
    final overlayMeshIps = await getOverlayMeshIps(workingDir, cluster);
    for (final entry in overlayMeshIps.entries) {
      substitutions['${entry.key}.overlayIp'] = entry.value;
    }
  }

  Map<String, String> nodeSubstitutions = Map.from(substitutions);
  nodeSubstitutions['localhost.hostname'] = node.name;
  nodeSubstitutions['localhost.ipv4'] = node.ipAddr;
  nodeSubstitutions['localhost.overlayIp'] =
      substitutions['${node.name}.overlayIp'] ??
          '-- overlayIp not found in etcd --';

  final sftp = await sshClient.sftp();
  await sftpMkDir(sftp, '/root/secrets');

  if (expectedSecrets.isNotEmpty) {
    if (debug) echoDebug("Deploy secrets on node ${node.name}");
    if (debug) echoDebug('Expected secrets: $expectedSecrets');
    // Deploy secrets to target node. A missing secret is skipped with a
    // warning; a secret that exists but cannot be read stops the deployment
    // of this node before anything is removed from /root/secrets.
    for (final secretName in expectedSecrets) {
      final secret = await loadSecretForDeploy(
          workingDir, secretsPwd, secretName,
          nodeName: node.name);
      if (secret == null) continue;
      final newSecret =
          substitute(secret, substitutions, expectedSecrets: expectedSecrets);
      await deploySecretOnRemote(
        workingDir,
        secretName,
        newSecret,
        node,
        sshClient: sshClient,
      );
    }
  }

  final expectedFilenamesOnRemot = ['.', '..'];
  expectedFilenamesOnRemot.addAll(expectedSecrets);

  final listOfFiles = await sftp.listdir('/root/secrets');
  for (final file in listOfFiles) {
    if (!expectedFilenamesOnRemot.contains(file.filename)) {
      echo('/root/secrets/${file.filename}');
      await sftp.remove('/root/secrets/${file.filename}');
    }
  }
  sftp.close();

  // TODO: Garbage collect unused secrets on target node
  // 1. check what secrets exist on remote
  // 2. remove if it not exists in expectedSecrets
}
