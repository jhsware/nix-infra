import 'package:args/command_runner.dart';

class SecretsCommand extends Command {
  @override
  final name = 'secrets';
  @override
  final description = 'Secrets management commands';

  SecretsCommand() {
    argParser
      ..addOption('working-dir', abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key', defaultsTo: 'nixinfra', help: 'SSH key name')
      ..addOption('env', help: 'Path to .env file')
      ..addFlag('batch', help: 'Run in batch mode');

    addSubcommand(StoreCommand());
    addSubcommand(UpdateCommand());
    addSubcommand(DestroyCommand());
  }
}

class StoreCommand extends Command {
  @override
  final name = 'store';
  @override
  final description = 'Store a new secret';

  @override
  void run() async {}
}

class UpdateCommand extends Command {
  @override
  final name = 'update';
  @override
  final description = 'Update an existing secret';

  @override
  void run() async {}
}

class DestroyCommand extends Command {
  @override
  final name = 'destroy';
  @override
  final description = 'Destroy a secret';

  @override
  void run() async {}
}

void main(List<String> arguments) {
  CommandRunner('nix-infra', 'Infrastructure management tool')
    ..addCommand(SecretsCommand())
    ..run(arguments);
}