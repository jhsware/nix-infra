import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:nix_infra/helpers.dart';
import 'commands/etcd.dart';
import 'commands/init.dart';
import 'commands/cluster.dart';
import 'commands/machine.dart';
import 'commands/ssh_key.dart';
import 'commands/cert.dart';
import 'commands/registry.dart';
import 'commands/secrets.dart';

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
      if (error is! UsageException && error is! ArgumentError) throw error;
      echo(error.toString());
      exit(64); // Exit code 64 indicates a usage error.
    });
  } catch (err) {
    if (err is Exception) {
      // Handle regular exceptions (from SSH, providers, etc.)
      // Extract just the message without "Exception:" prefix and stack trace
      final message = err.toString().replaceFirst('Exception: ', '');
      echo('ERROR: $message');
      exit(1);
    } else {
      // Handle any other errors
      echo('ERROR: ${err.toString()}');
      exit(1);
    }
  }
  exit(0);
}
