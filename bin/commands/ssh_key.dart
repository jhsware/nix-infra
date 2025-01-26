import 'package:args/command_runner.dart';

class SSHKeyCommand extends Command {
  @override
  final name = 'ssh-key';
  @override
  final description = 'SSH key management commands';

  SSHKeyCommand() {
    argParser
      ..addOption('working-dir', abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key', defaultsTo: 'nixinfra', help: 'SSH key name')
      ..addOption('env', help: 'Path to .env file')
      ..addFlag('batch', help: 'Run in batch mode');

    addSubcommand(CreateCommand());
    addSubcommand(AddCommand());
    addSubcommand(RemoveCommand());
  }
}

class CreateCommand extends Command {
  @override
  final name = 'create';
  @override
  final description = 'Create a new SSH key';

  @override
  void run() async {}
}

class AddCommand extends Command {
  @override
  final name = 'add';
  @override
  final description = 'Add SSH key to provider';

  AddCommand() {
    argParser.addOption('provider', mandatory: true);
  }

  @override
  void run() async {}
}

class RemoveCommand extends Command {
  @override
  final name = 'remove';
  @override
  final description = 'Remove SSH key from provider';

  RemoveCommand() {
    argParser.addOption('provider', mandatory: true);
  }

  @override
  void run() async {}
}

void main(List<String> arguments) {
  CommandRunner('nix-infra', 'Infrastructure management tool')
    ..addCommand(SSHKeyCommand())
    ..run(arguments);
}