import 'package:args/command_runner.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/ssh.dart';
import './shared.dart';
import './utils.dart';

class SshKeyCommand extends Command {
  @override
  final name = 'ssh-key';
  @override
  final description = 'Manage SSH keys for infrastructure access';

  SshKeyCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd', defaultsTo: '.', help: 'Directory to store SSH keys')
      ..addOption('env', help: 'Path to environment file');

    addSubcommand(CreateSshKeyCommand());
    addSubcommand(AddSshKeyCommand());
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
      ..addOption('name', help: 'SSH key name')
      ..addOption('email', help: 'SSH e-mail')
      ..addFlag('batch', defaultsTo: false);
  }

  @override
  void run() async {
    final workingDir = await getWorkingDirectory(parent?.argResults!['working-dir']);

    final bool batch = argResults!['batch'];
    final String sshKeyName = argResults!['name'];
    final String sshEmail = argResults!['email'];

    await createSshKeyPair(
      workingDir,
      sshEmail,
      sshKeyName,
      debug: false,
      batch: batch,
    );
  }
}

class AddSshKeyCommand extends Command {
  @override
  final name = 'add';
  @override
  final description = 'Add an SSH public key to cloud provider';

  AddSshKeyCommand() {
    argParser
      ..addOption('name', help: 'SSH key name')
      ..addFlag('batch', defaultsTo: false);
  }

  @override
  void run() async {
    final workingDir = await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = argResults!['name'];

    final provider = await getProvider(workingDir, env, sshKeyName);
    await provider.addSshKeyToCloudProvider(workingDir, sshKeyName);
  }
}

class RemoveSshKeyCommand extends Command {
  @override
  final name = 'remove';
  @override
  final description = 'Add an SSH public key to cloud provider';

  RemoveSshKeyCommand() {
    argParser
      ..addOption('name', help: 'SSH key name')
      ..addFlag('batch', defaultsTo: false);
  }

  @override
  void run() async {
    final workingDir = await getWorkingDirectory(parent?.argResults!['working-dir']);
    final env = await loadEnv(parent?.argResults!['env'], workingDir);

    final String sshKeyName = argResults!['name'];

    final provider = await getProvider(workingDir, env, sshKeyName);
    await provider.removeSshKeyFromCloudProvider(workingDir, sshKeyName);
  }
}
