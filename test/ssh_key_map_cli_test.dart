import 'dart:io';

import 'package:test/test.dart';

/// SSH_KEY_MAP_PATH through the real CLI entry point (docs/design/
/// ssh_agent_keys.md §6.3): a broken key map stops a command before any
/// connection, and SSH_KEY is optional with a key map. The CLI may print
/// the path of the key map.
///
/// No test here connects to a machine: each one stops at the key map or at
/// a target that is not in servers.yaml. Compiles nix-infra once per test.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_key_map_cli_');
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
  /// SSH_KEY_MAP_PATH or HCLOUD_TOKEN of the developer's shell does not leak
  /// in.
  Map<String, String> cleanEnvironment(Map<String, String> extra) {
    const passThrough = ['PATH', 'HOME', 'PUB_CACHE', 'TMPDIR'];
    return {
      for (final name in passThrough)
        if (Platform.environment[name] != null)
          name: Platform.environment[name]!,
      ...extra,
    };
  }

  /// `nix-infra fleet cmd -d <dir> --target=<target> uptime`
  Future<ProcessResult> fleetCmd(String target,
          {Map<String, String> environment = const {}}) =>
      Process.run(
        Platform.resolvedExecutable,
        [
          'run', '--verbosity=error', 'bin/nix_infra.dart', //
          'fleet', 'cmd', '-d', dir.path, '--target=$target', 'uptime',
        ],
        workingDirectory: Directory.current.path,
        environment: cleanEnvironment(environment),
        includeParentEnvironment: false,
      );

  const timeout = Timeout(Duration(minutes: 2));

  test('a key map of another version stops the command before connecting',
      () async {
    final map = File('${dir.path}/map.json')
      ..writeAsStringSync('{"version": 2}');
    final r = await fleetCmd('web001',
        environment: {'SSH_KEY': 'k', 'SSH_KEY_MAP_PATH': map.path});
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, 1, reason: output);
    expect(
        r.stdout,
        contains('- ERROR: The key map has version 2; nix-infra reads '
            'version 1. (SSH_KEY_MAP_PATH: ${map.path})'));
    expect(output, isNot(contains('192.0.2.10')));
  }, timeout: timeout);

  test('with a key map SSH_KEY is not needed', () async {
    File('${dir.path}/map.json').writeAsStringSync(
        '{"version": 1, "default": {"agent_key": "SHA256:x"}}');
    // A relative path of .env is relative to the project. The target is not
    // in servers.yaml: the command stops after the key map and the provider,
    // without a connection.
    File('${dir.path}/.env').writeAsStringSync('SSH_KEY_MAP_PATH=map.json\n');
    final r = await fleetCmd('not-a-server');
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, 1, reason: output);
    expect(output, isNot(contains('No SSH key configured')));
    expect(output, isNot(contains('The key map')));
    expect(output,
        contains('Server(s) not found in servers.yaml: not-a-server'));
  }, timeout: timeout);
}
