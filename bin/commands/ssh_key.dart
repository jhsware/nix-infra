import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/hcloud.dart';
import 'package:path/path.dart' as path;
import 'package:dotenv/dotenv.dart';
import './utils.dart';

class SshKeyCommand extends Command {
  @override
  final name = 'ssh-key';
  @override
  final description = 'Manage SSH keys for infrastructure access';

  SshKeyCommand() {
    addSubcommand(CreateSshKeyCommand());
    addSubcommand(RemoveSshKeyCommand());
  }
}

class CreateSshKeyCommand extends Command {
  @override
  final name = 'create';
  @override
  final description = 'Create a new SSH key pair';

  CreateSshKeyCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd', defaultsTo: '.', help: 'Directory to store SSH keys')
      ..addOption('ssh-key',
          defaultsTo: 'nixinfra', help: 'Name for the SSH key')
      ..addOption('env', help: 'Path to environment file')
      ..addFlag('batch',
          help: 'Run non-interactively using environment variables');
  }

  @override
  void run() async {
    final workingDir =
        Directory(path.normalize(path.absolute(argResults!['working-dir'])));
    final batch = argResults!['batch'] as bool;

    final env = DotEnv(includePlatformEnvironment: true);
    final envFile = File(argResults!['env'] ?? '${workingDir.path}/.env');
    if (await envFile.exists()) {
      env.load([envFile.path]);
    }

    final sshEmail = env['SSH_EMAIL'] ?? readInput('ssh e-mail', batch);
    final sshKeyName = env['SSH_KEY'] ?? argResults!['ssh-key'];

    await createSshKeyPair(
      workingDir,
      sshEmail,
      sshKeyName,
      debug: false,
      batch: batch,
    );
  }
}

class RemoveSshKeyCommand extends Command {
  @override
  final name = 'remove';
  @override
  final description = 'Remove an SSH key from cloud provider';

  RemoveSshKeyCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd', defaultsTo: '.', help: 'Working directory')
      ..addOption('ssh-key-name',
          mandatory: true, help: 'Name of SSH key to remove')
      ..addOption('env', help: 'Path to environment file');
  }

  @override
  void run() async {
    final workingDir =
        Directory(path.normalize(path.absolute(argResults!['working-dir'])));

    final env = DotEnv(includePlatformEnvironment: true);
    final envFile = File(argResults!['env'] ?? '${workingDir.path}/.env');
    if (await envFile.exists()) {
      env.load([envFile.path]);
    }

    if (env['HCLOUD_TOKEN'] == null) {
      echo('ERROR! env var HCLOUD_TOKEN not found');
      exit(2);
    }

    final hcloud = HetznerCloud(
        token: env['HCLOUD_TOKEN']!, sshKey: env['SSH_KEY'] ?? 'nixinfra');
    await hcloud.removeSshKeyFromCloudProvider(
        workingDir, argResults!['ssh-key-name']);
  }
}
