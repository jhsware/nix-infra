import 'dart:io';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
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
/// non-empty SSH_KEY of [env].
///
/// [parentArgs] are the parsed arguments of the parent command (fleet,
/// cluster, etcd, registry). They may be null, and a parent without an
/// `ssh-key` option counts as "option not given". An empty value counts as
/// not set, both for the option and for `SSH_KEY`.
///
/// Without a name:
/// - `SSH_KEY_PATH` set (not empty) and [requireName] false: returns `''`.
///   The command only connects, and SSH_KEY_PATH gives the key file of
///   every machine.
/// - [requireName] true (provision: the command gives the name to the
///   cloud provider): throws a readable Exception, also when SSH_KEY_PATH
///   is set.
/// - Otherwise: throws a readable Exception that names the three ways to
///   configure a key.
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

  if (requireName) {
    throw Exception('No SSH key configured. Set SSH_KEY in .env or the '
        'environment, or pass --ssh-key=<name>. This command gives the key '
        'name to the cloud provider, so SSH_KEY_PATH alone is not enough.');
  }

  final keyPath = env['SSH_KEY_PATH']?.trim();
  if (keyPath != null && keyPath.isNotEmpty) {
    return '';
  }

  throw Exception('No SSH key configured. Set SSH_KEY in .env or the '
      'environment, pass --ssh-key=<name>, or set '
      'SSH_KEY_PATH=<private key file>.');
}

/// The parsed arguments that hold the option [name] for the subcommand
/// [command]: those of the nearest ancestor where [name] was given on the
/// command line, else those of the nearest ancestor that declares [name]
/// (its default applies). Null when no ancestor declares [name].
///
/// The `etcd` group is mounted twice, as `nix-infra etcd` and as
/// `nix-infra cluster etcd`, and declares its own `-d`, `--ssh-key` and
/// `--env`. Reading only `parent.argResults` (the etcd group) dropped the
/// options of `cluster -d <dir> --ssh-key=<k> etcd nodes …`. With this
/// helper they reach the subcommand, and an option given to `etcd` still
/// wins; so does one written after the subcommand name, which the args
/// parser stores on the nearest command that declares it (the etcd group).
ArgResults? ancestorArgsWithOption(Command command, String name) {
  ArgResults? declaredBy;
  for (Command? c = command.parent; c != null; c = c.parent) {
    final args = c.argResults;
    // argParser, not args.options: ArgResults.options leaves out an option
    // without a default that was not given, and wasParsed throws for a name
    // that the parser does not declare.
    if (args == null || !c.argParser.options.containsKey(name)) continue;
    if (args.wasParsed(name)) return args;
    declaredBy ??= args;
  }
  return declaredBy;
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
