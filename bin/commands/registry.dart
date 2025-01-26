import 'package:args/command_runner.dart';

class RegistryCommand extends Command {
  @override
  final name = 'registry';
  @override
  final description = 'Registry management commands';

  RegistryCommand() {
    argParser
      ..addOption('working-dir', abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key', defaultsTo: 'nixinfra', help: 'SSH key name')
      ..addOption('env', help: 'Path to .env file')
      ..addFlag('batch', help: 'Run in batch mode');

    addSubcommand(PublishImageCommand());
    addSubcommand(ListImagesCommand());
  }
}

class PublishImageCommand extends Command {
  @override
  final name = 'publish-image';
  @override
  final description = 'Publish image to registry';

  PublishImageCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

class ListImagesCommand extends Command {
  @override
  final name = 'list-images';
  @override
  final description = 'List images in registry';

  ListImagesCommand() {
    argParser.addOption('target', mandatory: true);
  }

  @override
  void run() async {}
}

void main(List<String> arguments) {
  CommandRunner('nix-infra', 'Infrastructure management tool')
    ..addCommand(RegistryCommand())
    ..run(arguments);
}