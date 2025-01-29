import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nix_infra/certificates.dart';
import 'package:nix_infra/ssh.dart';
import 'package:nix_infra/helpers.dart';
import 'package:path/path.dart' as path;
import 'package:dotenv/dotenv.dart';
import './utils.dart';

class InitCommand extends Command {
  @override
  final name = 'init';
  @override
  final description =
      'Initialize new infrastructure with SSH keys and optional certificate authority';

  InitCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd',
          defaultsTo: '.',
          help: 'Directory to initialize infrastructure in')
      ..addOption('ssh-key',
          help: 'Name of the SSH key to generate')
      ..addOption('ssh-email',
          help: 'Name of the SSH key email')
      ..addOption('env',
          help: 'Path to environment file containing configuration values')
      ..addFlag('batch',
          help: 'Run non-interactively using values from environment variables')
      ..addFlag('no-cert-auth',
          help: 'Skip certificate authority creation (only generate SSH keys)',
          negatable: false);
  }

  @override
  void run() async {
    final workingDir = Directory(
        path.normalize(path.absolute(argResults!['working-dir'])));
    if (!await workingDir.exists()) {
      echo('ERROR! Working directory does not exist: ${workingDir.path}');
      exit(2);
    }

    // Load environment variables
    final env = DotEnv(includePlatformEnvironment: true);
    final envFile = File(argResults!['env'] ?? '${workingDir.path}/.env');
    if (await envFile.exists()) {
      env.load([envFile.path]);
    }

    final batch = argResults!['batch'] as bool;

    areYouSure(
        'Are you sure you want to init this directory (${workingDir.path})?',
        batch);

    final noCertAuth = argResults!['no-cert-auth'] as bool;

    if (!noCertAuth) {
      // Generate certificate authority if not disabled
      final pwdCa =
          env['CA_PASS'] ?? readPassword(ReadPasswordEnum.caRoot, batch);
      final pwdCaInt = env['INTERMEDIATE_CA_PASS'] ??
          readPassword(ReadPasswordEnum.caIntermediate, batch);
      final certEmail =
          env['CERT_EMAIL'] ?? readInput('certificate e-mail', batch);
      final certCountryCode = env['CERT_COUNTRY_CODE'] ?? 'SE';
      final certStateProvince = env['CERT_STATE_PROVINCE'] ?? 'unknown';
      final certCompany = env['CERT_COMPANY'] ?? 'unknown';

      await createCertificateAuthority(
        workingDir,
        pwdCa,
        pwdCaInt,
        certEmail: certEmail,
        certCountryCode: certCountryCode,
        certStateProvince: certStateProvince,
        certCompany: certCompany,
        batch: batch,
        debug: false,
      );
    }

    // Generate SSH key pair
    final sshKeyName = argResults!['ssh-key'] ?? env['SSH_KEY'] ?? readInput('ssh key name', batch);
    final sshEmail = argResults!['ssh-email'] ?? env['SSH_EMAIL'] ?? readInput('ssh e-mail', batch);
    await createSshKeyPair(
      workingDir,
      sshEmail,
      sshKeyName,
      debug: false,
      batch: batch,
    );

    exit(0);
  }
}
