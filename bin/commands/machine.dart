import 'package:args/command_runner.dart';

class MachineCommand extends Command {
  @override
  final name = 'machine';
  @override
  final description = 'Machine management commands';

  MachineCommand() {
    argParser
      ..addOption('working-dir', abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key', defaultsTo: 'nixinfra', help: 'SSH key name')
      ..addOption('env', help: 'Path to .env file')
      ..addFlag('batch', help: 'Run in batch mode');

    addSubcommand(ProvisionCommand());
    addSubcommand(UpdateCommand());
    addSubcommand(DestroyCommand());
    addSubcommand(DeployAppsCommand());
    addSubcommand(GCCommand());
    addSubcommand(UpgradeCommand());
    addSubcommand(RollbackCommand());
    addSubcommand(SSHCommand());
    addSubcommand(CmdCommand());
    addSubcommand(PortForwardCommand());
    addSubcommand(ActionCommand());
  }
}

class ProvisionCommand extends Command {
  @override
  final name = 'provision';
  @override
  final description = 'Provision new machines';

  ProvisionCommand() {
    argParser
      ..addOption('node-names', mandatory: true)
      ..addOption('provider', mandatory: true)
      ..addOption('nixos-version')
      ..addOption('machine-type')
      ..addOption('location')
      ..addOption('placement-group');
  }

  @override
  void run() async {}
}

class UpdateCommand extends Command {
  @override
  final name = 'update';
  @override
  final description = 'Update machine';

  UpdateCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class DestroyCommand extends Command {
  @override
  final name = 'destroy';
  @override
  final description = 'Destroy machine';

  DestroyCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class DeployAppsCommand extends Command {
  @override
  final name = 'deploy-apps';
  @override
  final description = 'Deploy applications to machine';

  DeployAppsCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class GCCommand extends Command {
  @override
  final name = 'gc';
  @override
  final description = 'Garbage collect machine';

  GCCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class UpgradeCommand extends Command {
  @override
  final name = 'upgrade';
  @override
  final description = 'Upgrade machine';

  UpgradeCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class RollbackCommand extends Command {
  @override
  final name = 'rollback';
  @override
  final description = 'Rollback machine';

  RollbackCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class SSHCommand extends Command {
  @override
  final name = 'ssh';
  @override
  final description = 'SSH into machine';

  SSHCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class CmdCommand extends Command {
  @override
  final name = 'cmd';
  @override
  final description = 'Run command on machine';

  CmdCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class PortForwardCommand extends Command {
  @override
  final name = 'port-forward';
  @override
  final description = 'Forward port from machine';

  PortForwardCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class ActionCommand extends Command {
  @override
  final name = 'action';
  @override
  final description = 'Run action on machine';

  ActionCommand() {
    argParser
      ..addOption('target', mandatory: true)
      ..addOption('cmd', mandatory: true);
  }

  @override
  void run() async {}
}

void main(List<String> arguments) {
  CommandRunner('nix-infra', 'Infrastructure management tool')
    ..addCommand(MachineCommand())
    ..run(arguments);
}