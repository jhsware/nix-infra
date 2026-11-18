import 'dart:io';

import 'package:test/test.dart';

/// Regression test: the `etcd` group under `cluster` declares its own `-d`,
/// `--ssh-key` and `--env`, and its subcommands read only those. The options
/// of `cluster -d <dir> --ssh-key=<k> etcd nodes …` were ignored: the
/// command ran in `.` without a key.
///
/// Runs the real CLI entry point, so it compiles nix-infra once per test.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_cluster_etcd_');
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

  /// `nix-infra cluster -d <dir> [clusterArgs] etcd nodes --target=x`
  Future<ProcessResult> clusterEtcdNodes(List<String> clusterArgs) {
    return Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        '--verbosity=error',
        'bin/nix_infra.dart',
        'cluster',
        '-d',
        dir.path,
        ...clusterArgs,
        'etcd',
        'nodes',
        '--target=x',
      ],
      workingDirectory: Directory.current.path,
      environment: cleanEnvironment(),
      includeParentEnvironment: false,
    );
  }

  test('cluster --ssh-key reaches etcd nodes', () async {
    final r = await clusterEtcdNodes(['--ssh-key=test-key']);
    final output = '${r.stdout}${r.stderr}';
    expect(output, isNot(contains('No SSH key configured')));
    // The empty project has no servers.yaml and no HCLOUD_TOKEN, so the
    // command stops at the next step: finding a provider.
    expect(output, contains('No provider configuration found'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cluster -d reaches etcd nodes (SSH_KEY from <dir>/.env)', () async {
    File('${dir.path}/.env').writeAsStringSync('SSH_KEY=test-key\n');
    final r = await clusterEtcdNodes([]);
    final output = '${r.stdout}${r.stderr}';
    expect(output, isNot(contains('No SSH key configured')));
    expect(output, contains('No provider configuration found'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
