import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:path/path.dart' as path;
import 'package:dotenv/dotenv.dart';
import './utils.dart';

class CertCommand extends Command {
  @override
  final name = 'cert';
  @override
  final description =
      'Certificate management commands for nodes and infrastructure';

  CertCommand() {
    argParser
      ..addOption('working-dir',
          abbr: 'd',
          defaultsTo: '.',
          help: 'Directory containing certificates and configuration')
      ..addOption('target',
          help: 'Target node names (space separated)', mandatory: true)
      ..addOption('ctrl-nodes',
          defaultsTo: 'etcd001 etcd002 etcd003',
          help: 'Control node names for cluster')
      ..addOption('cert-type',
          allowed: ['tls', 'peer'],
          defaultsTo: 'tls',
          help: 'Certificate type to generate (tls or peer)')
      ..addOption('env', help: 'Path to environment file')
      ..addFlag('batch',
          help: 'Run non-interactively using environment variables');
  }

  @override
  void run() async {
    final workingDir =
        Directory(path.normalize(path.absolute(argResults!['working-dir'])));
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
    final target = argResults!['target'] as String;
    final certType =
        argResults!['cert-type'] == 'peer' ? CertType.peer : CertType.tls;

    final pwdCaInt = env['INTERMEDIATE_CA_PASS'] ??
        readPassword(ReadPasswordEnum.caIntermediate, batch);

    final certEmail =
        env['CERT_EMAIL'] ?? readInput('certificate e-mail', batch);
    final certCountryCode = env['CERT_COUNTRY_CODE'] ?? 'SE';
    final certStateProvince = env['CERT_STATE_PROVINCE'] ?? 'unknown';
    final certCompany = env['CERT_COMPANY'] ?? 'unknown';

    // Implementation placeholder for certificate generation
    // TODO: Implement after HCloud service is available:
    // final hcloud = HetznerCloud(token: env['HCLOUD_TOKEN']!, sshKey: sshKeyName);
    // final nodes = await hcloud.getServers(only: target.split(' '));

    // await generateCerts(
    //   workingDir,
    //   nodes,
    //   [certType],
    //   passwordIntermediateCa: pwdCaInt,
    //   certEmail: certEmail,
    //   certCountryCode: certCountryCode,
    //   certStateProvince: certStateProvince,
    //   certCompany: certCompany,
    //   batch: batch,
    //   debug: false,
    // );

    // await deployEtcdCertsOnClusterNode(
    //   workingDir,
    //   nodes,
    //   [certType],
    //   debug: false
    // );

    echo(
        'Certificate management command implemented. Cloud provider integration pending.');
    exit(0);
  }
}
