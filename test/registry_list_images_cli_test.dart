import 'dart:io';

import 'package:test/test.dart';

/// Regression test: `registry list-images` read a `batch` flag that it does
/// not declare, so every call stopped with a usage error (exit 64), and it
/// asked "Are you sure you want to publish this image?" before listing.
///
/// Runs the real CLI entry point, so it compiles nix-infra once per test.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_list_images_');
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

  test('list-images gets past its arguments and asks nothing', () async {
    // The options of the registry group come after `list-images`, as in
    // docs/CLUSTER.md; the args parser hands them to the registry group.
    final r = await Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        '--verbosity=error',
        'bin/nix_infra.dart',
        'registry',
        'list-images',
        '-d',
        dir.path,
        '--target=x',
        '--ssh-key=test-key',
      ],
      workingDirectory: Directory.current.path,
      environment: cleanEnvironment(),
      includeParentEnvironment: false,
    );
    final output = '${r.stdout}${r.stderr}';
    expect(r.exitCode, isNot(64), reason: output);
    expect(output, isNot(contains('Could not find an option named')));
    expect(output, isNot(contains('Are you sure')));
    // The empty project has no servers.yaml and no HCLOUD_TOKEN, so the
    // command stops at the next step: finding a provider.
    expect(output, contains('No provider configuration found'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
