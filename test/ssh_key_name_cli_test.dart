import 'dart:io';

import 'package:test/test.dart';

/// Regression test for the 2026-11-17 report: in a project whose `.env` has
/// no SSH_KEY, and without --ssh-key, every command that reads the SSH key
/// name failed with "type 'Null' is not a subtype of type 'String'".
///
/// Runs the real CLI entry point, so it compiles nix-infra once per test.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_ssh_key_name_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Only what `dart run` needs from the process environment, so a SSH_KEY
  /// or HCLOUD_TOKEN of the developer's shell does not leak in.
  Map<String, String> cleanEnvironment() {
    const passThrough = ['PATH', 'HOME', 'PUB_CACHE', 'TMPDIR'];
    return {
      for (final name in passThrough)
        if (Platform.environment[name] != null)
          name: Platform.environment[name]!,
    };
  }

  /// `nix-infra fleet cmd -d <dir> [extraArgs] --target=x uptime`
  Future<ProcessResult> fleetCmd([List<String> extraArgs = const []]) {
    return Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        '--verbosity=error',
        'bin/nix_infra.dart',
        'fleet',
        'cmd',
        '-d',
        dir.path,
        ...extraArgs,
        '--target=x',
        'uptime',
      ],
      workingDirectory: Directory.current.path,
      environment: cleanEnvironment(),
      includeParentEnvironment: false,
    );
  }

  test('without SSH_KEY and --ssh-key the error names what to set', () async {
    final r = await fleetCmd();
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, 1, reason: output);
    expect(
        r.stdout,
        contains('- ERROR: No SSH key configured. Set SSH_KEY in .env or the '
            'environment, pass --ssh-key=<name>, or set '
            'SSH_KEY_PATH=<private key file>.'));
    expect(output, isNot(contains("type 'Null'")));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('SSH_KEY in .env passes the key name check', () async {
    File('${dir.path}/.env').writeAsStringSync('SSH_KEY=test-key\n');
    final r = await fleetCmd();
    final output = '${r.stdout}${r.stderr}';
    expect(output, isNot(contains('No SSH key configured')));
    // The empty project has no servers.yaml and no HCLOUD_TOKEN, so the
    // command stops at the next step: finding a provider.
    expect(output, contains('No provider configuration found'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('--ssh-key passes the key name check', () async {
    final r = await fleetCmd(['--ssh-key=test-key']);
    final output = '${r.stdout}${r.stderr}';
    expect(output, isNot(contains('No SSH key configured')));
    expect(output, contains('No provider configuration found'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
