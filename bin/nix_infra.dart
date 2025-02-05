import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'commands/etcd.dart';
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
      ..addCommand(FleetCommand())
      ..addCommand(ClusterCommand())
      ..addCommand(SshKeyCommand())
      ..addCommand(CertCommand())
      ..addCommand(RegistryCommand())
      ..addCommand(EtcdCommand())
      ..addCommand(SecretsCommand());
    await cmd.run(arguments).catchError((error) {
      if (error is! UsageException) throw error;
      print(error);
      exit(64); // Exit code 64 indicates a usage error.
    });
  } catch (err) {
    if (err is FormatException) {
      await legacyCommands(arguments);
    }
  }
  exit(0);
}
