import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/secret_codec.dart';
import 'package:nix_infra/secrets.dart';
import 'utils.dart';


class SecretsCommand extends Command {
  @override
  final name = 'secrets';
  @override
  final description = 'Manage encrypted secrets';

  SecretsCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd', defaultsTo: '.', help: 'Directory containing secrets')
      ..addOption('env', help: 'Path to environment file');

    addSubcommand(StoreCommand());
    addSubcommand(ReadCommand());
    addSubcommand(ListCommand());
    addSubcommand(NewKeyCommand());
    addSubcommand(MigrateCommand());
  }
}

class ListCommand extends Command {
  @override
  final name = 'list';
  @override
  final description =
      'List the secret files with format, kind, created and modified time '
      '(no key needed, nothing is decrypted)';

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final rows = listSecretFiles(workingDir);
    if (rows.isEmpty) {
      stderr.writeln('No secret files in ${workingDir.path}/secrets');
      return;
    }
    for (final line in formatSecretListRows(rows)) {
      stdout.writeln(line);
    }
  }
}

class NewKeyCommand extends Command {
  @override
  final name = 'new-key';
  @override
  final description =
      'Print a new generated files key (the key on stdout, instructions on stderr)';

  @override
  void run() async {
    stdout.writeln(generateFilesKey());
    stderr.writeln('''

This is a new files key. It is shown only once: store it now.

In a new project, store it as SECRETS_PASS (in .env, or in the sysops vault).

To use it in a project that already has secret files:
  1. Put the old key in SECRETS_PASS and the new key in NEW_SECRETS_PASS.
  2. Run: nix-infra secrets migrate --new-key-env NEW_SECRETS_PASS
  3. Store the new key as SECRETS_PASS (in .env, or in the sysops vault)
     and remove NEW_SECRETS_PASS.''');
  }
}

class MigrateCommand extends Command {
  @override
  final name = 'migrate';
  @override
  final description =
      'Encrypt legacy secret files (base64 and OpenSSL) as v2, or re-encrypt '
      'all secret files with a new key (--new-key-env)';

  MigrateCommand() {
    argParser
      ..addFlag('batch', defaultsTo: false, help: 'Do not ask for confirmation')
      ..addFlag('dry-run',
          defaultsTo: false, help: 'Only list what would be changed')
      ..addOption('new-key-env',
          help: 'Name of the environment variable with the new key; all files '
              'are re-encrypted from SECRETS_PASS to this key');
  }

  @override
  void run() async {
    final workingDir =
        await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final bool dryRun = argResults!['dry-run'];
    final String? newKeyEnv = argResults!['new-key-env'];

    String? newKey;
    if (newKeyEnv != null) {
      newKey = env[newKeyEnv];
      if (newKey == null || newKey.isEmpty) {
        echo('ERROR! The environment variable $newKeyEnv is not set or empty');
        exit(2);
      }
      if (newKey.startsWith(kFilesKeyPrefix) && !isGeneratedFilesKey(newKey)) {
        echo('ERROR! $newKeyEnv starts with $kFilesKeyPrefix but is not a '
            'valid generated files key');
        exit(2);
      }
    }

    final rows = listSecretFiles(workingDir);
    final targets = <(SecretListRow, String)>[];
    var unchanged = 0;
    for (final row in rows) {
      final String action;
      if (row.isLink) {
        action = 'symbolic link, left unchanged';
      } else {
        switch (row.secretFormat!) {
          case SecretFileFormat.v2:
            if (newKey == null) {
              unchanged++;
              continue;
            }
            action = 're-encrypt with the new key';
          case SecretFileFormat.opensslSalted:
          case SecretFileFormat.legacyBase64:
            action = newKey == null
                ? 'encrypt as v2'
                : 'encrypt as v2 with the new key';
          case SecretFileFormat.unknown:
            action = 'unknown format, left unchanged';
        }
      }
      targets.add((row, action));
    }

    if (targets.isEmpty) {
      echo(rows.isEmpty
          ? 'No secret files in ${workingDir.path}/secrets'
          : 'Nothing to migrate: all ${rows.length} secret files are v2');
      return;
    }

    echo('Secret files to migrate:');
    final nameWidth =
        targets.map((t) => t.$1.name.length).fold(4, (a, b) => a > b ? a : b);
    final formatWidth = targets
        .map((t) => t.$1.format.length)
        .fold(6, (a, b) => a > b ? a : b);
    echo('  ${'NAME'.padRight(nameWidth)}  ${'FORMAT'.padRight(formatWidth)}  ACTION');
    for (final (row, action) in targets) {
      echo('  ${row.name.padRight(nameWidth)}  '
          '${row.format.padRight(formatWidth)}  $action');
    }
    if (unchanged > 0) {
      echo('$unchanged v2 secret files are not changed');
    }

    if (dryRun) return;

    final oldKey = getSecretsPassword(env, batch);
    if (newKey != null && newKey == oldKey) {
      echo('ERROR! $newKeyEnv holds the same key as SECRETS_PASS');
      exit(2);
    }

    areYouSure('Migrate ${targets.length} secret files?', batch);

    var converted = 0;
    var skipped = 0;
    final failed = <MigrateResult>[];
    for (final (row, _) in targets) {
      final result = await migrateSecret(workingDir, row.name,
          oldKey: oldKey, newKey: newKey ?? oldKey);
      switch (result.status) {
        case MigrateStatus.converted:
          converted++;
          echo('${row.name}: encrypted as v2');
        case MigrateStatus.skipped:
          skipped++;
          echo('${row.name}: skipped (${result.reason})');
        case MigrateStatus.failed:
          failed.add(result);
          echo('${row.name}: FAILED (${result.reason})');
      }
    }

    echo('Converted: $converted, skipped: $skipped, failed: ${failed.length}');
    if (failed.isNotEmpty) {
      echo('ERROR! These secret files were not migrated and are unchanged: '
          '${failed.map((r) => r.name).join(', ')}');
      if (newKey != null) {
        echo('Fix them and run the command again; files already encrypted '
            'with the new key are skipped. Keep both keys until it succeeds.');
      }
      exit(1);
    }

    if (newKey != null) {
      echo('All secret files are encrypted with the new key. Now store the '
          'new key as SECRETS_PASS (in .env, or in the sysops vault) and '
          'remove $newKeyEnv.');
    }
    if (!isGeneratedFilesKey(newKey ?? oldKey)) {
      echo('Note: the key is a password. A generated files key '
          '(`nix-infra secrets new-key`) is stronger and faster to use.');
    }
  }
}

class StoreCommand extends Command {
  @override
  final name = 'store';
  @override
  final description = 'Store a secret';

  StoreCommand() {
    argParser.addFlag('batch', defaultsTo: false);
    argParser.addFlag('overwrite',
        defaultsTo: false, help: 'Replace an existing secret with this name');
    argParser.addOption('secret',
        help: 'Secret value as a string (for single-line secrets)');
    argParser.addOption('secret-file',
        help: 'Path to a file containing the secret (for multi-line secrets)');
    argParser.addOption('name', mandatory: true);
  }

  @override
  void run() async {
    final workingDir = await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    // final bool debug = parent?.argResults!['debug'];
    final bool batch = argResults!['batch'];
    final bool overwrite = argResults!['overwrite'];
    final String? secretOption = argResults!['secret'];
    final String? secretFilePath = argResults!['secret-file'];
    final String secretName = argResults!['name'];

    // Resolve secret value from --secret, --secret-file, or stdin
    final String secret = await resolveSecret(
      secretOption: secretOption,
      secretFilePath: secretFilePath,
    );

    final secretsPwd = getSecretsPassword(env, batch);

    try {
      await saveSecret(workingDir, secretsPwd, secretName, secret,
          overwrite: overwrite);
    } on SecretExists {
      echo('ERROR! Secret "$secretName" exists. Use --overwrite to replace it.');
      exit(2);
    }
    echo('Secret saved as $secretName');
  }
}

class ReadCommand extends Command {
  @override
  final name = 'read';
  @override
  final description = 'Read and decrypt a secret';

  ReadCommand() {
    argParser.addFlag('batch', defaultsTo: false);
    argParser.addOption('name', mandatory: true, help: 'Secret name to read');
  }

  @override
  void run() async {
    final workingDir = await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final bool batch = argResults!['batch'];
    final String secretName = argResults!['name'];

    final secretsPwd = getSecretsPassword(env, batch);

    try {
      final secret = await readSecret(workingDir, secretsPwd, secretName);
      stdout.write(secret);
    } catch (e) {
      echo('ERROR: $e');
      exit(1);
    }
  }
}

/// Resolve the secret value from one of three sources (in priority order):
/// 1. `--secret-file` reads file contents, preserving multi-line
/// 2. `--secret` inline string value
/// 3. stdin (piped input)
///
/// Throws if no secret is provided from any source.
Future<String> resolveSecret({
  String? secretOption,
  String? secretFilePath,
}) async {
  if (secretOption != null && secretFilePath != null) {
    echo('ERROR! Cannot specify both --secret and --secret-file');
    exit(2);
  }

  if (secretFilePath != null) {
    final file = File(secretFilePath);
    if (!file.existsSync()) {
      echo('ERROR! Secret file not found: $secretFilePath');
      exit(2);
    }
    return await file.readAsString();
  }

  if (secretOption != null) {
    return secretOption;
  }

  // Try reading from stdin (for piped input)
  if (!stdin.hasTerminal) {
    final input = await stdin.transform(const SystemEncoding().decoder).join();
    if (input.isNotEmpty) {
      return input;
    }
  }

  echo('ERROR! No secret provided. Use --secret, --secret-file, or pipe via stdin');
  exit(2);
}