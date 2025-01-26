import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nix_infra/secrets.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as path;
import 'package:dotenv/dotenv.dart';
import 'utils.dart';

class SecretsCommand extends Command {
  @override
  final name = 'secrets';
  @override
  final description = 'Manage encrypted secrets';

  SecretsCommand() {
    argParser
      ..addOption(
        'working-dir',
        abbr: 'd',
        defaultsTo: '.',
        help: 'Directory containing secrets'
      )
      ..addOption(
        'secret',
        mandatory: true,
        help: 'Secret value to store'
      )
      ..addOption(
        'save-as',
        mandatory: true,
        help: 'Name to save the secret under'
      )
      ..addOption(
        'env',
        help: 'Path to environment file'
      )
      ..addFlag(
        'batch',
        help: 'Run non-interactively using environment variables'
      );
  }

  @override
  void run() async {
    final workingDir = Directory(path.normalize(path.absolute(argResults!['working-dir'])));
    final batch = argResults!['batch'] as bool;

    // Load environment variables
    final env = DotEnv(includePlatformEnvironment: true);
    final envFile = File(argResults!['env'] ?? '${workingDir.path}/.env');
    if (await envFile.exists()) {
      env.load([envFile.path]);
    }

    final secretsPwd = env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);
    final secret = argResults!['secret'];
    final secretName = argResults!['save-as'];

    await saveSecret(workingDir, secretsPwd, secretName, secret);
    echo('Secret saved as $secretName');
  }
}