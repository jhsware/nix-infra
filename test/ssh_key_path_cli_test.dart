import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

/// SSH_KEY_PATH through the real CLI entry point: key resolution stops a
/// command before any connection, and SSH_KEY is optional with it.
///
/// No test here connects to a machine: each one stops at the key file or at
/// a target that is not in servers.yaml. Compiles nix-infra once per test.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_ssh_key_path_cli_');
    // One machine, on an address of TEST-NET-1 (RFC 5737), never reached.
    File('${dir.path}/servers.yaml').writeAsStringSync('''
servers:
  web001:
    ip: 192.0.2.10
    ssh_key: ./ssh/web001
''');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Only what `dart run` needs from the process environment, so a SSH_KEY,
  /// SSH_KEY_PATH or HCLOUD_TOKEN of the developer's shell does not leak in.
  Map<String, String> cleanEnvironment([Map<String, String> extra = const {}]) {
    const passThrough = ['PATH', 'HOME', 'PUB_CACHE', 'TMPDIR'];
    return {
      for (final name in passThrough)
        if (Platform.environment[name] != null)
          name: Platform.environment[name]!,
      ...extra,
    };
  }

  /// `nix-infra fleet <args> -d <dir>` with only [environment] set.
  Future<ProcessResult> fleet(List<String> args,
      {Map<String, String> environment = const {}}) {
    return Process.run(
      Platform.resolvedExecutable,
      ['run', '--verbosity=error', 'bin/nix_infra.dart', 'fleet', ...args],
      workingDirectory: Directory.current.path,
      environment: cleanEnvironment(environment),
      includeParentEnvironment: false,
    );
  }

  /// `nix-infra fleet cmd -d <dir> --target=<target> uptime`
  Future<ProcessResult> fleetCmd(String target,
          {Map<String, String> environment = const {}}) =>
      fleet(['cmd', '-d', dir.path, '--target=$target', 'uptime'],
          environment: environment);

  const timeout = Timeout(Duration(minutes: 2));

  test('a missing SSH_KEY_PATH file stops the command before connecting',
      () async {
    final r = await fleetCmd('web001',
        environment: {'SSH_KEY_PATH': '/does/not/exist'});
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, 1, reason: output);
    expect(
        r.stdout,
        contains('- ERROR: SSH_KEY_PATH names a file that does not exist: '
            '/does/not/exist. If a sysops terminal set it: unlock the vault '
            'and open a new terminal.'));
    expect(output, isNot(contains('No SSH key configured')));
    expect(output, isNot(contains('192.0.2.10')));
  }, timeout: timeout);

  test('a relative SSH_KEY_PATH of .env is relative to the project',
      () async {
    File('${dir.path}/.env').writeAsStringSync('SSH_KEY_PATH=keys/missing\n');
    final r = await fleetCmd('web001');
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, 1, reason: output);
    expect(
        output,
        contains('SSH_KEY_PATH names a file that does not exist: '
            '${path.normalize('${dir.path}/keys/missing')}.'));
  }, timeout: timeout);

  test('with an existing SSH_KEY_PATH file SSH_KEY is not needed', () async {
    final key = File('${dir.path}/id_test')..writeAsStringSync('unused');
    // The target is not in servers.yaml: the command stops after the key
    // and the provider were resolved, without a connection.
    final r = await fleetCmd('not-a-server',
        environment: {'SSH_KEY_PATH': key.path});
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, 1, reason: output);
    expect(output, isNot(contains('No SSH key configured')));
    expect(output, isNot(contains('SSH_KEY_PATH names a file')));
    expect(output, contains('Server(s) not found in servers.yaml: not-a-server'));
  }, timeout: timeout);

  test('SSH_KEY_PATH of the environment wins over .env', () async {
    File('${dir.path}/.env')
        .writeAsStringSync('SSH_KEY_PATH=/stale/from-env-file\n');
    final key = File('${dir.path}/id_test')..writeAsStringSync('unused');
    final r = await fleetCmd('not-a-server',
        environment: {'SSH_KEY_PATH': key.path});
    final output = '${r.stdout}${r.stderr}';
    expect(output, isNot(contains('/stale/from-env-file')));
    expect(output, contains('Server(s) not found in servers.yaml'));
  }, timeout: timeout);

  test('without SSH_KEY_PATH and SSH_KEY the error names all three settings',
      () async {
    final r = await fleetCmd('web001');
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, 1, reason: output);
    expect(
        r.stdout,
        contains('- ERROR: No SSH key configured. Set SSH_KEY in .env or the '
            'environment, pass --ssh-key=<name>, or set '
            'SSH_KEY_PATH=<private key file>.'));
  }, timeout: timeout);

  test('provision still needs the key name with SSH_KEY_PATH', () async {
    final key = File('${dir.path}/id_test')..writeAsStringSync('unused');
    final r = await fleet(
        ['provision', '-d', dir.path, '--node-names=web002'],
        environment: {'SSH_KEY_PATH': key.path});
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, 1, reason: output);
    expect(
        r.stdout,
        contains('- ERROR: No SSH key configured. Set SSH_KEY in .env or the '
            'environment, or pass --ssh-key=<name>. This command gives the '
            'key name to the cloud provider, so SSH_KEY_PATH alone is not '
            'enough.'));
  }, timeout: timeout);
}
