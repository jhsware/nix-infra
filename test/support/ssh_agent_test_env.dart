// A part of ssh_test_env.dart: it shares the private helpers of
// [SshTestEnv], which is built on it.
part of 'ssh_test_env.dart';

/// A running `ssh-agent` with test keys, without `sshd`. Needs [tools].
///
/// The private key files are given to the agent and then deleted, so only
/// the agent holds the keys.
class SshAgentTestEnv {
  SshAgentTestEnv._(this.dir, this.socket, this.publicKeyFiles, this._process);

  /// The tools that [start] needs.
  static const tools = ['ssh-agent', 'ssh-add', 'ssh-keygen'];

  /// The temporary folder: the socket and the public key files.
  final Directory dir;

  /// The socket of the agent (`SSH_AUTH_SOCK`).
  final String socket;

  /// The public key file of each test key, by key name.
  final Map<String, String> publicKeyFiles;

  final Process _process;

  /// The public key line of the test key [name]: `<type> <base64> <comment>`.
  String publicKeyLine(String name) =>
      File(publicKeyFiles[name]!).readAsStringSync().trim();

  /// The public key blob of the test key [name].
  Uint8List publicKeyBlob(String name) =>
      base64.decode(publicKeyLine(name).split(' ')[1]);

  /// Starts an agent in a new temporary folder with the test keys [keys]
  /// (names of [sshTestKeyTypes]) and deletes their private key files.
  ///
  /// Throws a [StateError] with the output of the tool when a step fails.
  static Future<SshAgentTestEnv> start({
    List<String> keys = const ['ed25519', 'rsa', 'ecdsa'],
  }) async {
    final missing = missingSshTools(tools);
    if (missing.isNotEmpty) {
      throw StateError('${missing.join(', ')} not on PATH');
    }
    final dir = SshTestEnv._tempDir();
    try {
      return await _startIn(dir, keys);
    } catch (_) {
      SshTestEnv._deleteDir(dir);
      rethrow;
    }
  }

  /// Starts the agent in [dir]; the caller deletes [dir] on an error.
  static Future<SshAgentTestEnv> _startIn(
    Directory dir,
    List<String> keys,
  ) async {
    final socket = path.join(dir.path, 'agent.sock');
    final process =
        await Process.start(findSshTool('ssh-agent')!, ['-D', '-a', socket]);
    try {
      final output = StringBuffer();
      process.stdout.transform(utf8.decoder).listen(output.write);
      process.stderr.transform(utf8.decoder).listen(output.write);
      await SshTestEnv._waitFor(
        () =>
            FileSystemEntity.typeSync(socket) != FileSystemEntityType.notFound,
        () => 'ssh-agent did not make its socket:\n$output',
      );

      final publicKeyFiles = <String, String>{};
      for (final name in keys) {
        final args = sshTestKeyTypes[name];
        if (args == null) throw ArgumentError.value(name, 'keys');
        final keyFile = path.join(dir.path, name);
        await SshTestEnv._run(findSshTool('ssh-keygen')!, [
          '-q', ...args, '-N', '', '-C', 'nix-infra-test-$name', //
          '-f', keyFile,
        ]);
        await SshTestEnv._run(
          findSshTool('ssh-add')!,
          [keyFile],
          environment: {'SSH_AUTH_SOCK': socket},
        );
        File(keyFile).deleteSync();
        publicKeyFiles[name] = '$keyFile.pub';
      }
      return SshAgentTestEnv._(dir, socket, publicKeyFiles, process);
    } catch (_) {
      process.kill();
      rethrow;
    }
  }

  /// Removes the test key [name] from the agent (`ssh-add -d`).
  Future<void> removeKey(String name) => SshTestEnv._run(
        findSshTool('ssh-add')!,
        ['-d', publicKeyFiles[name]!],
        environment: {'SSH_AUTH_SOCK': socket},
      );

  /// Stops the agent and deletes [dir].
  Future<void> stop() async {
    await _kill();
    SshTestEnv._deleteDir(dir);
  }

  Future<void> _kill() async {
    _process.kill();
    await _process.exitCode
        .timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }
}