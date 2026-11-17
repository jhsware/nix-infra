import 'dart:io';
import 'package:args/args.dart';
import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/helpers.dart';



String readInput(String label, bool batch) {
  // TODO: Consider using (interact)[https://github.com/frencojobs/interact] for input
  String? inp;
  if (!batch) {
    stdout.write('Enter $label: ');
    // TODO: Hide input
    inp = stdin.readLineSync();
  }

  if (inp == null || inp == '') {
    echo('ERROR! You may not leave $label null or empty');
    exit(2);
  }

  return inp;
}

enum ReadPasswordEnum { caRoot, caIntermediate, secrets }

final caPasswordLabel = {
  ReadPasswordEnum.caRoot: 'CA root',
  ReadPasswordEnum.caIntermediate: 'CA Intermediate',
  ReadPasswordEnum.secrets: 'secrets',
};

String readPassword(ReadPasswordEnum type, bool batch) {
  // TODO: Consider using (interact)[https://github.com/frencojobs/interact] for input
  String? pwd;
  if (!batch) {
    stdout.write('Enter ${caPasswordLabel[type]} password: ');
    // TODO: Hide input
    pwd = stdin.readLineSync();
  }

  if (pwd == null || pwd == '') {
    echo('ERROR! ${caPasswordLabel[type]} password cannot be null or empty');
    exit(2);
  }

  return pwd;
}

String getSecretsPassword(DotEnv env, bool batch) {

  // 1. Check SECRETS_PASS first (preferred)
  final fromPass = env['SECRETS_PASS'];
  if (fromPass != null && fromPass.isNotEmpty) {
    return fromPass;
  }

  // 2. Check SECRETS_PWD (deprecated fallback)
  final fromPwd = env['SECRETS_PWD'];
  if (fromPwd != null && fromPwd.isNotEmpty) {
    stderr.writeln(
        'WARNING: SECRETS_PWD is deprecated, use SECRETS_PASS instead');
    return fromPwd;
  }

  // 3. Fall back to interactive prompt
  return readPassword(ReadPasswordEnum.secrets, batch);
}

/// The SSH key name of a command: --ssh-key of the parent command, else a
/// non-empty SSH_KEY of [env]. Throws a readable Exception when neither is set.
///
/// [parentArgs] are the parsed arguments of the parent command (fleet,
/// cluster, etcd, registry). They may be null, and a parent without an
/// `ssh-key` option counts as "option not given". An empty value counts as
/// not set, both for the option and for `SSH_KEY`.
///
/// [requireName]: the command gives the name to the cloud provider
/// (provision). It has no effect yet; the SSH_KEY_PATH task uses it.
String resolveSshKeyName(ArgResults? parentArgs, DotEnv env,
    {bool requireName = false}) {
  final fromOption = parentArgs?.options.contains('ssh-key') == true
      ? parentArgs!['ssh-key'] as String?
      : null;
  if (fromOption != null && fromOption.isNotEmpty) {
    return fromOption;
  }

  final fromEnv = env['SSH_KEY'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }

  throw Exception('No SSH key configured. Set SSH_KEY in .env or the '
      'environment, or pass --ssh-key=<name>.');
}


void areYouSure(String txt, bool batch) {
  // TODO: Consider using (interact)[https://github.com/frencojobs/interact] for input
  if (batch) return;

  stdout.write('$txt [y/n] ');
  final inp = stdin.readLineSync();
  if (inp != 'y') {
    echo('Aborted');
    exit(1);
  }
}

String prefixWithNodeName(String nodeName, String inp) {
  final tmp = inp.split('\n');
  final outp = tmp.map((str) => '$nodeName: $str');
  return outp.join('\n');
}
