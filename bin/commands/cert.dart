import 'package:args/command_runner.dart';

class CertCommand extends Command {
  @override
  final name = 'cert';
  @override
  final description = 'Certificate management commands';

  CertCommand() {
    argParser
      ..addOption('working-dir', abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key', defaultsTo: 'nixinfra', help: 'SSH key name')
      ..addOption('env', help: 'Path to .env file')
      ..addFlag('batch', help: 'Run in batch mode');

    addSubcommand(CreateCommand());
    addSubcommand(RenewCommand());
    addSubcommand(RevokeCommand());
    addSubcommand(ShowCommand());
  }
}

class CreateCommand extends Command {
  @override
  final name = 'create';
  @override
  final description = 'Create a new certificate';

  @override
  void run() async {}
}

class RenewCommand extends Command {
  @override
  final name = 'renew';
  @override
  final description = 'Renew an existing certificate';

  @override
  void run() async {}
}

class RevokeCommand extends Command {
  @override
  final name = 'revoke';
  @override
  final description = 'Revoke a certificate';

  @override
  void run() async {}
}

class ShowCommand extends Command {
  @override
  final name = 'show';
  @override
  final description = 'Show certificate details';

  @override
  void run() async {}
}

void main(List<String> arguments) {
  CommandRunner('nix-infra', 'Infrastructure management tool')
    ..addCommand(CertCommand())
    ..run(arguments);
}