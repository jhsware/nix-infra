import 'dart:io';

import 'package:args/command_runner.dart';
import 'commands/init.dart';
import 'commands/cluster.dart';
import 'commands/machine.dart';
import 'commands/ssh_key.dart';
import 'commands/cert.dart';
import 'commands/registry.dart';
import 'commands/secrets.dart';
import 'commands/legacy.dart';

void main(List<String> arguments) async {
  try {
    final cmd = CommandRunner('nix-infra', 'Infrastructure management tool')
      ..addCommand(InitCommand())
      ..addCommand(MachineCommand())
      ..addCommand(ClusterCommand())
      ..addCommand(SshKeyCommand())
      ..addCommand(CertCommand())
      ..addCommand(RegistryCommand())
      ..addCommand(SecretsCommand());
    await cmd.run(arguments)
        .catchError((error) {
          if (error is! UsageException) throw error;
          print(error);
          exit(64); // Exit code 64 indicates a usage error.
        });
    exit(0);
  } catch (err) {
    rethrow;
    // await legacyCommands(arguments);
    exit(0);
  }
}
