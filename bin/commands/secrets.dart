import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nix_infra/secrets.dart';
import 'package:nix_infra/helpers.dart';
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
    argParser.addOption('secret', mandatory: true);
    argParser.addOption('name', mandatory: true);
  }

  @override
  void run() async {
    final workingDir = await getWorkingDirectory(argResults!['working-dir']);
    final env = await loadEnv(argResults!['env'], workingDir);

    // final bool debug = argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String secret = argResults!['secret'];
    final String secretName = argResults!['name'];

    final secretsPwd =
        env['SECRETS_PWD'] ?? readPassword(ReadPasswordEnum.secrets, batch);

    await saveSecret(workingDir, secretsPwd, secretName, secret);
    echo('Secret saved as $secretName');
  }
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
//     final workingDir = await getWorkingDirectory(argResults!['working-dir']);
//     final env = await loadEnv(argResults!['env'], workingDir);

//     // final bool debug = argResults!['debug'];
//     final bool batch = argResults!['batch'];
//     final String secret = argResults!['secret'];
//     final String secretName = argResults!['name'];
    
//     // 1. Check that it exists
//     // 2. Remove the secret
//     // 3. QUESTION: Should we remove it from machines?
//     // 4. QUESTION: Should we add an update that can update on all machines too?

//   }
// }
