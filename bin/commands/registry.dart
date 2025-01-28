import 'package:args/command_runner.dart';
import 'package:nix_infra/docker_registry.dart';
import 'package:nix_infra/hcloud.dart';
import 'utils.dart';

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
          help: 'Name of machine hosting the registry', mandatory: true)
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
      ..addOption('file', mandatory: true, help: 'Image file path')
      ..addOption('image-name', mandatory: true, help: 'Name for the image');
  }

  @override
  void run() async {
    final workingDir = await getWorkingDirectory(argResults!['working-dir']);
    final env = await loadEnv(argResults!['env'], workingDir);

    // final bool debug = argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String sshKeyName = argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');
    final String fileName = argResults!['file'];
    final String imageName = argResults!['image-name'];

    areYouSure('Are you sure you want to publish this image?', batch);

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
    final nodes = await hcloud.getServers(only: targets);
    final cluster = await hcloud.getServers();

    await publishImageToRegistry(workingDir, cluster, nodes.first,
        file: fileName, name: imageName);
  }
}

class ListImagesCommand extends Command {
  @override
  final name = 'list-images';
  @override
  final description = 'List images in the container registry';

  ListImagesCommand();

  @override
  void run() async {
    final workingDir = await getWorkingDirectory(argResults!['working-dir']);
    final env = await loadEnv(argResults!['env'], workingDir);

    // final bool debug = argResults!['debug'];
    final bool batch = argResults!['batch'];
    final String sshKeyName = argResults!['ssh-key'] ?? env['SSH_KEY'];
    final String hcloudToken = env['HCLOUD_TOKEN']!;
    final List<String> targets = argResults!['target'].split(' ');

    areYouSure('Are you sure you want to publish this image?', batch);

    final hcloud = HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
    final nodes = await hcloud.getServers(only: targets);
    final cluster = await hcloud.getServers();

    await listImagesInRegistry(workingDir, cluster, nodes.first);
  }
}
