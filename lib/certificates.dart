import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nix_infra/ssh.dart';
import 'package:dartssh2/dartssh2.dart';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:process_run/shell.dart';

import 'templates/opensslCnfCaOrig.dart';
import 'templates/openSslCnfInterOrig.dart';

Future<void> createCertificateAuthority(
  Directory workingDir,
  String passwordCa,
  String passwordIntermediateCa, {
  String certEmail = "sebastian@urbantalk.se",
  String certCountryCode = "SE",
  String certStateProvince = "Sweden",
  String certCompany = "Urbantalk",
  bool debug = false,
}) async {
  // Followed this guide:
  // https://jamielinux.com/docs/openssl-certificate-authority/create-the-root-pair.html
  echo('******************************************');
  echo('*** Create Local Certificate Authority ***');
  echo('******************************************');

  final controller = StreamController<List<int>>();
  controller.stream.listen((inp) {
    final str = utf8.decode(inp);
    if (debug) {
      stdout.write(str);
    } else {
      stdout.write('§');
    }
  }, onError: (inp) {
    final str = utf8.decode(inp);
    stderr.write('ERROR: $str');
  }, onDone: () {
    stdout.write('!');
  });

  final shell = Shell(
    environment: {
      'CA_PASS': passwordCa,
      'INTERMEDIATE_CA_PASS': passwordIntermediateCa,
    },
    runInShell: true,
    stdout: controller.sink,
    verbose: debug,
  );

  final caDir = Directory('${workingDir.path}/ca');
  if (caDir.existsSync()) {
    echo('CA already exists, skipping creation');
  } else {
    echo('Creating CA');
    mkdir(caDir.path, names: ['certs', 'crl', 'newcerts', 'private']);
    File('${caDir.path}/index.txt').writeAsStringSync('');
    File('${caDir.path}/serial').writeAsStringSync('1000');
    File('${caDir.path}/openssl.cnf').writeAsStringSync(openSslCnfCaOrig(
      caDir.path,
      certEmail: certEmail,
      certCountryCode: certCountryCode,
      certStateProvince: certStateProvince,
      certCompany: certCompany,
    ));
    await shell.run('chmod 700 ${caDir.path}/private');
  }

  final caKeyFile = File('${caDir.path}/private/ca.key.pem');
  if (caKeyFile.existsSync()) {
    echo('Root CA key already exists, skipping creation');
  } else {
    echo('Creating root CA key');
    await shell.run(
        'openssl genrsa -aes256 -passout env:CA_PASS -out ${caKeyFile.path} 4096');
    await shell.run('chmod 400 ${caKeyFile.path}');
  }

  final caCertFile = File('${caDir.path}/certs/ca.cert.pem');
  if (caCertFile.existsSync()) {
    echo('Root CA certificate already exists, skipping creation');
  } else {
    echo('Creating root CA certificate');
    final cmd = [
      'openssl req -config ${caDir.path}/openssl.cnf',
      '-key ${caKeyFile.path}',
      '-subj "/C=SE/ST=Sweden/O=Urbantalk/CN=Urbantalk Root CA/emailAddress=sebastian@urbantalk.se"',
      '-new -x509 -days 7300 -sha256 -extensions v3_ca',
      '-out ${caCertFile.path}',
      '-passin env:CA_PASS',
      (debug ? "" : " -batch"),
    ];
    await shell.run(cmd.join(' '));
    await shell.run('chmod 444 ${caCertFile.path}');
  }

  final intermediateCaDir = Directory('${workingDir.path}/ca/intermediate');
  if (intermediateCaDir.existsSync()) {
    echo('Intermediate CA already exists, skipping creation');
  } else {
    echo('Creating intermediate CA');
    mkdir(caDir.path, names: 'intermediate');
    mkdir(intermediateCaDir.path,
        names: ['certs', 'crl', 'csr', 'newcerts', 'private']);
    File('${intermediateCaDir.path}/index.txt').writeAsStringSync('');
    File('${intermediateCaDir.path}/serial').writeAsStringSync('1000');
    File('${intermediateCaDir.path}/crlnumber').writeAsStringSync('1000');
    File('${intermediateCaDir.path}/openssl.cnf')
        .writeAsStringSync(openSslCnfInterOrig(
      intermediateCaDir.path,
      certEmail: certEmail,
      certCountryCode: certCountryCode,
      certStateProvince: certStateProvince,
      certCompany: certCompany,
    ));

    await shell.run('chmod 700 ${intermediateCaDir.path}/private');
  }

  final intermediateCaKeyFile =
      File('${intermediateCaDir.path}/private/intermediate.key.pem');
  if (intermediateCaKeyFile.existsSync()) {
    echo('Intermediate CA key already exists, skipping creation');
  } else {
    echo('Creating intermediate CA key ');
    await shell.run(
        'openssl genrsa -aes256 -passout env:INTERMEDIATE_CA_PASS -out ${intermediateCaKeyFile.path} 4096');
    await shell.run('chmod 400 ${intermediateCaKeyFile.path}');
  }

  final intermediateCaCsrFile =
      File('${intermediateCaDir.path}/csr/intermediate.csr.pem');
  if (intermediateCaCsrFile.existsSync()) {
    echo('Intermediate CA CSR already exists, skipping creation');
  } else {
    echo('Creating intermediate CA CSR');
    final cmd = [
      'openssl req -config ${intermediateCaDir.path}/openssl.cnf',
      '-new -sha256',
      '-key ${intermediateCaKeyFile.path}',
      '-subj "/C=SE/ST=Sweden/O=Urbantalk/CN=Urbantalk Intermediate CA/emailAddress=sebastian@urbantalk.se"',
      '-out ${intermediateCaCsrFile.path}',
      '-passin env:INTERMEDIATE_CA_PASS',
      (debug ? "" : " -batch"),
    ];
    await shell.run(cmd.join(' '));
  }

  final intermediateCaCertFile =
      File('${intermediateCaDir.path}/certs/intermediate.cert.pem');
  if (intermediateCaCertFile.existsSync()) {
    echo('Intermediate CA certificate already exists, skipping creation');
  } else {
    echo('Creating intermediate CA certificate');
    await shell.run(
        'openssl rsa -in ${caKeyFile.path} -passin env:CA_PASS -check -noout');
    try {
      final cmd = [
        'openssl ca -config ${caDir.path}/openssl.cnf',
        '-extensions v3_intermediate_ca -days 3650 -notext -md sha256',
        '-in ${intermediateCaCsrFile.path}',
        '-out ${intermediateCaCertFile.path}',
        '-passin env:CA_PASS',
        (debug ? "" : " -batch"),
      ];
      await shell.run(cmd.join(' '));
      await shell.run('chmod 444 ${intermediateCaCertFile.path}');
    } catch (err) {
      print(err);
    }
  }

  echo('******************************************');
}

Future<void> generateCerts(
    Directory workingDir, Iterable<ClusterNode> nodes, Iterable<CertType> certs,
    {required String passwordIntermediateCa, bool debug = false}) async {
  final controller = StreamController<List<int>>();
  controller.stream.listen((inp) {
    final str = utf8.decode(inp);
    if (debug) {
      stdout.write(str);
    } else {
      stdout.write('§');
    }
  }, onError: (inp) {
    final str = utf8.decode(inp);
    stderr.write('ERROR: $str');
  }, onDone: () {
    stdout.write('!');
  });

  final shell = Shell(
    environment: {'INTERMEDIATE_CA_PASS': passwordIntermediateCa},
    stdout: controller.sink,
    verbose: debug,
  );
  echo("Generating certificate chain");
  final intermediateCaDir = Directory('${workingDir.path}/ca/intermediate');

  final caChainCert = File('${intermediateCaDir.path}/certs/ca-chain.cert.pem');
  if (caChainCert.existsSync()) {
    echo('...ca chain already exists');
  } else {
    final intermediateCaCertFile =
        File('${intermediateCaDir.path}/certs/intermediate.cert.pem');
    final caCertFile = File('${workingDir.path}/ca/certs/ca.cert.pem');

    caChainCert.writeAsStringSync([
      caCertFile.readAsStringSync(),
      intermediateCaCertFile.readAsStringSync(),
    ].join(''));
    await shell.run('chmod 444 ${caChainCert.path}');
  }

  for (final node in nodes) {
    echo("Generating AUTH certs for ${node.name}");
    // ignore: no_leading_underscores_for_local_identifiers, non_constant_identifier_names
    final __CONF__ = File('${intermediateCaDir.path}/openssl-${node.name}.cnf');

    final openSslConfTemplate =
        File('${intermediateCaDir.path}/openssl.cnf').readAsStringSync();

    // sedInPlace "s/\[%%SUBJ_ALT_NAME%%\]/DNS:$_node.$DOMAIN, IP:127.0.0.1/g" $__CONF__
    final openSslConfContent = openSslConfTemplate.replaceAll(
      RegExp(r'\[%%SUBJ_ALT_NAME%%\]'),
      'IP:${node.ipAddr}, IP:127.0.0.1',
    );
    // You can use this for debugging that subjectAltName is set correctly:
    // echo('******** ${node.name} ********');
    // echo(openSslConfContent);
    // echo('******************************');
    __CONF__.writeAsStringSync(openSslConfContent);

    for (final cert in certs) {
      final certType = cert == CertType.tls ? 'client' : 'peer';

      // ignore: no_leading_underscores_for_local_identifiers, non_constant_identifier_names
      final __KEY__ = File(
          '${intermediateCaDir.path}/private/${node.name}-$certType-tls.key.pem');
      // ignore: no_leading_underscores_for_local_identifiers, non_constant_identifier_names
      final __CSR__ = File(
          '${intermediateCaDir.path}/private/${node.name}-$certType-tls.csr.pem');
      // ignore: no_leading_underscores_for_local_identifiers, non_constant_identifier_names
      final __CERT__ = File(
          '${intermediateCaDir.path}/private/${node.name}-$certType-tls.cert.pem');

      if (!__KEY__.existsSync()) {
        await shell.run('openssl genrsa -out ${__KEY__.path} 2048');
        await shell.run('chmod 400 ${__KEY__.path}');
      } else {
        echo('...client key already exists for ${node.name}');
      }

      if (!__CSR__.existsSync()) {
        // Create a config file for this node
        final cmd = [
          'openssl req -config ${__CONF__.path}',
          '-key ${__KEY__.path}',
          '-subj "/C=SE/ST=Sweden/O=Urbantalk/CN=${node.name} $certType tls/emailAddress=sebastian@urbantalk.se"',
          // Consider checking how to use the field added to openSslConfContent above
          '-addext "subjectAltName = IP:${node.ipAddr}, IP:127.0.0.1"',
          '-new -sha256',
          '-out ${__CSR__.path}',
          '-passin env:INTERMEDIATE_CA_PASS',
          (debug ? "" : " -batch"),
        ];
        await shell.run(cmd.join(' '));
        // """openssl req -config ${__CONF__.path} -key ${__KEY__.path} -subj "/C=SE/ST=Sweden/O=Urbantalk/CN=${node.name} $certType tls/emailAddress=sebastian@urbantalk.se" -addext "subjectAltName = IP:${node.ipAddr}, IP:127.0.0.1" -new -sha256 -out ${__CSR__.path} -passin env:INTERMEDIATE_CA_PASS -batc""");
      } else {
        echo('...client tls CSR already exists for ${node.name}');
      }

      if (!__CERT__.existsSync()) {
        // Valid for 5 years
        await shell.run(
            """openssl ca -config ${__CONF__.path} -extensions ${certType}_tls -days 1835 -notext -md sha256 -in ${__CSR__.path} -out ${__CERT__.path} -passin env:INTERMEDIATE_CA_PASS -batch""");
        await shell.run('chmod 444 ${__CERT__.path}');
      } else {
        echo('...client tls cert already exists for ${node.name}');
      }

      // Remove the CSR file
      __CSR__.delete();
    }
    // Remove the temporary config file
    __CONF__.delete();
  }
}

Future<void> deployEtcdCertsOnClusterNode(
  Directory workingDir,
  Iterable<ClusterNode> nodes,
  Iterable<CertType> certs, {
  bool debug = false,
}) async {
  for (final node in nodes) {
    final intermediateCaDir = Directory('${workingDir.path}/ca/intermediate');

    final files = <File>[];
    files.add(File('${intermediateCaDir.path}/certs/ca-chain.cert.pem'));

    for (final cert in certs) {
      final certType = cert == CertType.tls ? 'client' : 'peer';
      files.add(File(
          '${intermediateCaDir.path}/private/${node.name}-$certType-tls.key.pem'));
      files.add(File(
          '${intermediateCaDir.path}/private/${node.name}-$certType-tls.cert.pem'));
    }

    echo('Deploying certs to ${node.name} (${node.ipAddr})');
    final sshClient = SSHClient(
      await SSHSocket.connect(node.ipAddr, 22),
      username: 'root',
      identities: [
        ...SSHKeyPair.fromPem(await getSshKeyAsPem(workingDir, node.sshKeyName))
      ],
    );
    final sftp = await sshClient.sftp();
    final stat =
        await sftp.stat('/root/certs').catchError((err) => SftpFileAttrs());
    if (!stat.isDirectory) {
      await sftp.mkdir('/root/certs');
    }
    for (final file in files) {
      if (debug) echoDebug('- ${fileName(file)}');
      final absFilePath = '/root/certs/${fileName(file)}';
      final stat =
          await sftp.stat(absFilePath).catchError((err) => SftpFileAttrs());
      if (stat.isFile) {
        await sftp.remove(absFilePath);
      }
      final remoteFile = await sftp.open(absFilePath,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate);
      await remoteFile.write(file.openRead().cast());
      await remoteFile.close();
    }
    sftp.close();

    // Set proper permissions on certs
    final shell = await getSshShell(sshClient);
    final script = """\\
    chmod 400 /root/certs/*
    chmod 700 /root/certs
    exit 0;
    """;
    shell.write(Uint8List.fromList(utf8.encode(script)));
    await shell.done;
    sshClient.close();
  }
}
