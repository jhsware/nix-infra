import 'package:args/command_runner.dart';

class InitCommand extends Command {
  @override
  final name = 'init';
  @override
  final description = 'Initialize new infrastructure';

  InitCommand() {
    argParser
      ..addOption('working-dir', abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key', defaultsTo: 'nixinfra', help: 'SSH key name')
      ..addOption('env', help: 'Path to .env file')
      ..addFlag('batch', help: 'Run in batch mode')
      ..addFlag('no-cert-auth', help: 'Skip certificate authority creation');
  }

  @override
  void run() async {}
}

void main(List<String> arguments) {
  CommandRunner('nix-infra', 'Infrastructure management tool')
    ..addCommand(InitCommand())
    ..run(arguments);
}