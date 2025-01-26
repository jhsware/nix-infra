import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nix_infra/docker_registry.dart';
import 'package:nix_infra/hcloud.dart';
import 'package:nix_infra/helpers.dart';
import 'package:path/path.dart' as path;
import 'package:dotenv/dotenv.dart';

class RegistryCommand extends Command {
  @override
  final name = 'registry';
  @override
  final description = 'Manage container registry and images';

  RegistryCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd',
          defaultsTo: '.',
          help: 'Directory containing certificates and configuration')
      ..addOption('target',
          help: 'Target node names (space separated)', mandatory: true)
      ..addOption('env', help: 'Path to environment file')
      ..addFlag('batch',
          help: 'Run non-interactively using environment variables');

    addSubcommand(PublishImageCommand());
    addSubcommand(ListImagesCommand());
  }
}

class PublishImageCommand extends Command {
  @override
  final name = 'publish-image';
  @override
  final description = 'Publish a container image to the registry';

  PublishImageCommand() {
    argParser
      ..addOption('image-name', mandatory: true, help: 'Name for the image')
      ..addOption('file', mandatory: true, help: 'Image file path');
  }

  @override
  void run() async {
    final workingDir = Directory(path.normalize(path.absolute(argResults!['working-dir'])));
    if (!await workingDir.exists()) {
      echo('ERROR! Working directory does not exist: ${workingDir.path}');
      exit(2);
    }

    final env = DotEnv(includePlatformEnvironment: true);
    final envFile = File(argResults!['env'] ?? '${workingDir.path}/.env');
    if (await envFile.exists()) {
      env.load([envFile.path]);
    }

    if (env['HCLOUD_TOKEN'] == null) {
      echo('ERROR! env var HCLOUD_TOKEN not found');
      exit(2);
    }

    final hcloud = HetznerCloud(token: env['HCLOUD_TOKEN']!, sshKey: env['SSH_KEY'] ?? 'nixinfra');
    final nodes = await hcloud.getServers(only: [argResults!['target']]);
    final cluster = await hcloud.getServers();
    
    await publishImageToRegistry(
      workingDir, 
      cluster, 
      nodes.first,
      file: argResults!['file'],
      name: argResults!['image-name']
    );
  }
}

class ListImagesCommand extends Command {
  @override
  final name = 'list-images';
  @override
  final description = 'List images in the container registry';

  ListImagesCommand() {}

  @override
  void run() async {
    final workingDir = Directory(path.normalize(path.absolute(argResults!['working-dir'])));
    if (!await workingDir.exists()) {
      echo('ERROR! Working directory does not exist: ${workingDir.path}');
      exit(2);
    }

    final env = DotEnv(includePlatformEnvironment: true);
    final envFile = File(argResults!['env'] ?? '${workingDir.path}/.env');
    if (await envFile.exists()) {
      env.load([envFile.path]);
    }

    if (env['HCLOUD_TOKEN'] == null) {
      echo('ERROR! env var HCLOUD_TOKEN not found');
      exit(2);
    }

    final hcloud = HetznerCloud(token: env['HCLOUD_TOKEN']!, sshKey: env['SSH_KEY'] ?? 'nixinfra');
    final nodes = await hcloud.getServers(only: [argResults!['target']]);
    final cluster = await hcloud.getServers();
    
    await listImagesInRegistry(workingDir, cluster, nodes.first);
  }
}