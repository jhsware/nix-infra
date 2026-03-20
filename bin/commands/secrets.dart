import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:nix_infra/helpers.dart';
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
  }
}

class StoreCommand extends Command {
  @override
  final name = 'store';
  @override
  final description = 'Store a secret';

  StoreCommand() {
    argParser.addFlag('batch', defaultsTo: false);
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
    final String? secretOption = argResults!['secret'];
    final String? secretFilePath = argResults!['secret-file'];
    final String secretName = argResults!['name'];

    // Resolve secret value from --secret, --secret-file, or stdin
    final String secret = await resolveSecret(
      secretOption: secretOption,
      secretFilePath: secretFilePath,
    );

    final secretsPwd =
        env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

    await saveSecret(workingDir, secretsPwd, secretName, secret);
    echo('Secret saved as $secretName');
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

// class DestoryCommand extends Command {
//   @override
//   final name = 'destroy';
//   @override
//   final description = 'Destroy a secret';

//   DestoryCommandz() {
//     argParser.addFlag('batch', defaultsTo: false);
//     argParser.addOption('name', mandatory: true);
//   }

//   @override
//   void run() async {
//     final workingDir = await getWorkingDirectory(parent?.argResults!['working-dir']);
//     final env = await loadEnv(parent?.argResults!['env'], workingDir);

//     // final bool debug = parent?.argResults!['debug'];
//     final bool batch = argResults!['batch'];
//     final String secret = argResults!['secret'];
//     final String secretName = argResults!['name'];
    
//     // 1. Check that it exists
//     // 2. Remove the secret
//     // 3. QUESTION: Should we remove it from machines?
//     // 4. QUESTION: Should we add an update that can update on all machines too?

//   }
// }
