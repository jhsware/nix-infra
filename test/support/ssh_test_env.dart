import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

part 'ssh_agent_test_env.dart';

// A local `ssh-agent` and `sshd` for tests (docs/design/ssh_agent_keys.md
// §10). Made for the trial of §11 step 1 (branch trial/ssh-agent-dartssh2-4,
// not merged); the agent mode tasks reuse it. The upgrade of dartssh2 (§11
// step 2) added [SshdKeyFileTestEnv]: a local `sshd` for the key files of a
// project, with no agent. Agent mode 1 added [SshAgentTestEnv] (in the part
// ssh_agent_test_env.dart): an agent with test keys, with no `sshd`;
// [SshTestEnv] is one of them and an `sshd`.
//
// Everything lives in one temporary folder: the agent socket, the host key,
// the public keys, `authorized_keys`, the sshd config and its pid file. The
// private keys of an [SshAgentTestEnv] are given to the agent and then
// deleted, so only the agent holds them. `sshd` runs as the current user on
// 127.0.0.1 and a free port, and logs to stderr (kept in
// [SshTestEnv.sshdLog]).

/// The `ssh-keygen` arguments of the test keys, by name. The private key of
/// a test key is `<dir>/<name>` (deleted after `ssh-add`), the public key
/// `<dir>/<name>.pub`.
const sshTestKeyTypes = <String, List<String>>{
  'rsa': ['-t', 'rsa', '-b', '2048'],
  'ed25519': ['-t', 'ed25519'],
  'ecdsa': ['-t', 'ecdsa', '-b', '256'],
};

/// Folders where `sshd` usually is. They are searched after PATH, because
/// an `sbin` folder is not on every PATH.
const _sbinDirs = ['/usr/sbin', '/usr/local/sbin', '/opt/homebrew/sbin'];

/// The absolute path of the tool [name] on PATH, or null. `sshd` is also
/// looked for in the usual `sbin` folders.
String? findSshTool(String name) {
  final dirs = [
    ...(Platform.environment['PATH'] ?? '')
        .split(':')
        .where((d) => d.isNotEmpty),
    if (name == 'sshd') ..._sbinDirs,
  ];
  for (final dir in dirs) {
    final file = File(path.join(dir, name));
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}

/// The tools of [tools] (by default [SshTestEnv.tools]) that cannot be
/// found.
List<String> missingSshTools([List<String> tools = SshTestEnv.tools]) => [
      for (final tool in tools)
        if (findSshTool(tool) == null) tool,
    ];

/// The `skip` value of a test that needs [tools] (by default an
/// [SshTestEnv]; [SshAgentTestEnv.tools] for an [SshAgentTestEnv],
/// [SshdKeyFileTestEnv.tools] for an [SshdKeyFileTestEnv]): false, or a text
/// that names the missing tools.
Object sshTestEnvSkip([List<String> tools = SshTestEnv.tools]) {
  final missing = missingSshTools(tools);
  return missing.isEmpty ? false : '${missing.join(', ')} not on PATH';
}

/// A running `ssh-agent` with test keys and a local `sshd` that accepts them.
class SshTestEnv {
  SshTestEnv._(this.dir, this.port, this.user, this._agent, this._sshd);

  /// The tools that [start] needs.
  static const tools = ['ssh-agent', 'ssh-add', 'ssh-keygen', 'sshd'];

  /// The temporary folder of this environment.
  final Directory dir;

  /// The port of `sshd` on 127.0.0.1.
  final int port;

  /// The current user, the only user `sshd` can log in.
  final String user;

  final SshAgentTestEnv _agent;
  final _Sshd _sshd;

  /// The socket of the agent (`SSH_AUTH_SOCK`).
  String get agentSocket => _agent.socket;

  /// The public key file of each test key, by key name.
  Map<String, String> get publicKeyFiles => _agent.publicKeyFiles;

  /// Everything `sshd` wrote so far (`-e`, `LogLevel DEBUG2`).
  String get sshdLog => _sshd.log.toString();

  /// The length of [sshdLog] now: a mark for [sshdLogLines] and
  /// [waitForSshdLog].
  int get sshdLogMark => _sshd.log.length;

  /// The lines of [sshdLog] after the mark [from].
  List<String> sshdLogLines({int from = 0}) =>
      sshdLog.substring(from).split('\n').where((l) => l.isNotEmpty).toList();

  /// Waits until a line after the mark [from] matches [test], and returns it.
  Future<String> waitForSshdLog(
    bool Function(String line) test, {
    int from = 0,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (final line in sshdLogLines(from: from)) {
        if (test(line)) return line;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'No such line in the sshd log after $timeout:\n'
          '${sshdLog.substring(from)}',
        );
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  /// The public key line of the test key [name]: `<type> <base64> <comment>`.
  String publicKeyLine(String name) => _agent.publicKeyLine(name);

  /// The public key blob of the test key [name].
  Uint8List publicKeyBlob(String name) => _agent.publicKeyBlob(name);

  /// Removes the test key [name] from the agent (`ssh-add -d`).
  Future<void> removeAgentKey(String name) => _agent.removeKey(name);

  /// Starts an agent with the test keys [keys] (names of [sshTestKeyTypes]),
  /// deletes their private key files, and starts `sshd` with all of them as
  /// authorized keys.
  ///
  /// Throws a [StateError] with the output of the tool when a step fails,
  /// for example when `sshd` cannot start as the current user.
  static Future<SshTestEnv> start({
    List<String> keys = const ['rsa', 'ed25519'],
  }) async {
    final missing = missingSshTools();
    if (missing.isNotEmpty) {
      throw StateError('${missing.join(', ')} not on PATH');
    }
    final dir = _tempDir();
    SshAgentTestEnv? agent;
    try {
      agent = await SshAgentTestEnv._startIn(dir, keys);
      final sshd = await _Sshd.start(
        dir,
        sshKeygen: findSshTool('ssh-keygen')!,
        sshd: findSshTool('sshd')!,
        authorizedKeys: agent.publicKeyFiles.values,
      );
      return SshTestEnv._(dir, sshd.port, _currentUser(), agent, sshd);
    } catch (_) {
      await agent?._kill();
      _deleteDir(dir);
      rethrow;
    }
  }

  /// Stops `sshd` and the agent and deletes the temporary folder.
  Future<void> stop() async {
    _sshd.process.kill();
    await Future.wait([
      _sshd.process.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: () => -1),
      _agent._kill(),
    ]);
    _deleteDir(dir);
  }

  /// A short folder: a Unix socket path has at most 104 bytes on macOS.
  static Directory _tempDir() {
    final tmp = Directory('/tmp');
    final base = tmp.existsSync() ? tmp : Directory.systemTemp;
    return base.createTempSync('nix_infra_ssh_');
  }

  static void _deleteDir(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the system to clean up.
    }
  }

  static Future<void> _run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    final result = await Process.run(
      executable,
      args,
      environment: environment,
    );
    if (result.exitCode != 0) {
      throw StateError(
        '${path.basename(executable)} failed '
        '(${result.exitCode}): ${result.stderr}${result.stdout}',
      );
    }
  }

  static Future<void> _waitFor(
    bool Function() done,
    String Function() failure,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) throw StateError(failure());
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  static Future<void> _waitForPort(
    int port,
    int? Function() exitCode,
    StringBuffer log,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final code = exitCode();
      if (code != null) {
        throw StateError(
          'sshd ended with exit code $code before it '
          'listened on port $port:\n$log',
        );
      }
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 200),
        );
        socket.destroy();
        return;
      } on SocketException {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('sshd does not listen on port $port:\n$log');
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  static String _currentUser() {
    final result = Process.runSync('id', ['-un']);
    if (result.exitCode == 0) return (result.stdout as String).trim();
    final user = Platform.environment['USER'];
    if (user == null || user.isEmpty) {
      throw StateError('The current user is not known.');
    }
    return user;
  }
}

/// A free TCP port on 127.0.0.1 (bound, then closed again).
Future<int> freeLocalPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// A running `sshd` in a temporary folder, as the current user on 127.0.0.1
/// and a free port. Its host key, config, `authorized_keys` and pid file are
/// in that folder; it logs to stderr ([log]).
class _Sshd {
  _Sshd(this.process, this.log, this.port);

  final Process process;
  final StringBuffer log;
  final int port;

  /// Makes a host key in [dir], writes [authorizedKeys] (public key files)
  /// to `authorized_keys` and starts `sshd` with [logLevel]. The config
  /// allows the SFTP subsystem and (the default) TCP forwarding.
  static Future<_Sshd> start(
    Directory dir, {
    required String sshKeygen,
    required String sshd,
    required Iterable<String> authorizedKeys,
    String logLevel = 'DEBUG2',
  }) async {
    final hostKey = path.join(dir.path, 'host_ed25519');
    await SshTestEnv._run(sshKeygen, [
      '-q', '-t', 'ed25519', '-N', '', '-C', 'nix-infra-test-host', //
      '-f', hostKey,
    ]);

    final authorizedKeysFile = File(path.join(dir.path, 'authorized_keys'));
    authorizedKeysFile.writeAsStringSync(
      [
        for (final file in authorizedKeys) File(file).readAsStringSync().trim(),
        '',
      ].join('\n'),
    );

    final port = await freeLocalPort();
    final config = File(path.join(dir.path, 'sshd_config'));
    config.writeAsStringSync(
      [
        'Port $port',
        'ListenAddress 127.0.0.1',
        'HostKey $hostKey',
        'AuthorizedKeysFile ${authorizedKeysFile.path}',
        'PidFile ${path.join(dir.path, 'sshd.pid')}',
        'StrictModes no',
        'UsePAM no',
        'PubkeyAuthentication yes',
        'PasswordAuthentication no',
        'KbdInteractiveAuthentication no',
        'LogLevel $logLevel',
        'Subsystem sftp internal-sftp',
        '',
      ].join('\n'),
    );

    final process = await Process.start(sshd, ['-D', '-e', '-f', config.path]);
    final log = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(log.write);
    process.stderr.transform(utf8.decoder).listen(log.write);
    int? exitCode;
    process.exitCode.then((code) => exitCode = code);
    try {
      await SshTestEnv._waitForPort(port, () => exitCode, log);
    } catch (_) {
      process.kill();
      rethrow;
    }
    return _Sshd(process, log, port);
  }
}

/// A local `sshd` that accepts the key files of a project, the classic way
/// of nix-infra: no agent. Needs [tools].
///
/// The temporary folder [dir] is also the project folder of the test: the
/// key files are `ssh/<name>` and `ssh/<name>.pub`, made by
/// `ssh-keygen -t rsa -b 2048 -N ''` as `nix-infra init` makes them.
class SshdKeyFileTestEnv {
  SshdKeyFileTestEnv._(this.dir, this.port, this.user, this._sshd);

  /// The tools that [start] needs.
  static const tools = ['ssh-keygen', 'sshd'];

  /// The temporary folder: the project folder of the test, and the folder
  /// of `sshd`.
  final Directory dir;

  /// The port of `sshd` on 127.0.0.1.
  final int port;

  /// The current user, the only user `sshd` can log in.
  final String user;

  final _Sshd _sshd;

  /// Everything `sshd` wrote so far (`-e`, `LogLevel INFO`).
  String get sshdLog => _sshd.log.toString();

  /// The private key file of the key [name]: `<dir>/ssh/<name>`.
  String keyFile(String name) => path.join(dir.path, 'ssh', name);

  /// Makes the key files of [keys] in `<dir>/ssh/`, and starts `sshd` with
  /// the public keys of [authorized] (all of [keys] when null).
  ///
  /// Throws a [StateError] with the output of the tool when a step fails.
  static Future<SshdKeyFileTestEnv> start({
    List<String> keys = const ['test-key'],
    List<String>? authorized,
  }) async {
    final missing = missingSshTools(tools);
    if (missing.isNotEmpty) {
      throw StateError('${missing.join(', ')} not on PATH');
    }
    final sshKeygen = findSshTool('ssh-keygen')!;
    final sshdTool = findSshTool('sshd')!;

    final dir = SshTestEnv._tempDir();
    try {
      final sshDir = Directory(path.join(dir.path, 'ssh'))..createSync();
      for (final name in keys) {
        await SshTestEnv._run(sshKeygen, [
          '-q', '-t', 'rsa', '-b', '2048', '-N', '', //
          '-C', 'nix-infra-test-$name',
          '-f', path.join(sshDir.path, name),
        ]);
      }

      final sshd = await _Sshd.start(
        dir,
        sshKeygen: sshKeygen,
        sshd: sshdTool,
        // Not DEBUG2: at DEBUG2 the session process of sshd writes lines
        // such as "debug2: do_setup_env: set TMPDIR" into the stderr of the
        // command, which runCommandOverSsh returns with its stdout.
        logLevel: 'INFO',
        authorizedKeys: [
          for (final name in authorized ?? keys)
            '${path.join(sshDir.path, name)}.pub',
        ],
      );

      return SshdKeyFileTestEnv._(
          dir, sshd.port, SshTestEnv._currentUser(), sshd);
    } catch (_) {
      SshTestEnv._deleteDir(dir);
      rethrow;
    }
  }

  /// Stops `sshd` and deletes the temporary folder.
  Future<void> stop() async {
    _sshd.process.kill();
    await _sshd.process.exitCode
        .timeout(const Duration(seconds: 5), onTimeout: () => -1);
    SshTestEnv._deleteDir(dir);
  }
}
