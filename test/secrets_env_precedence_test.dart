import 'dart:io';

import 'package:nix_infra/secret_codec.dart';
import 'package:nix_infra/secrets.dart';
import 'package:test/test.dart';

/// Regression test for the 2026-11-10 incident: the files key was given in
/// the process environment (a sysops terminal grant), the project `.env`
/// still had an old password in `SECRETS_PASS`, and the `.env` value won.
///
/// Runs the real CLI entry point, so it compiles nix-infra once per run.
void main() {
  const secretName = 'precedence-test';
  const stalePassword = 'old_style_password_0123456789ab';

  late Directory dir;
  late String key;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nix_infra_env_precedence_');
    key = generateFilesKey();
    await saveSecret(dir, key, secretName, 'hello');
    File('${dir.path}/.env').writeAsStringSync('SECRETS_PASS=$stalePassword\n');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<ProcessResult> readSecretCli(Map<String, String> environment) {
    return Process.run(
      Platform.resolvedExecutable,
      [
        'run',
        '--verbosity=error',
        'bin/nix_infra.dart',
        'secrets',
        '-d',
        dir.path,
        'read',
        '--batch',
        '--name=$secretName',
      ],
      workingDirectory: Directory.current.path,
      environment: environment,
    );
  }

  test('SECRETS_PASS in the process environment beats a stale .env line',
      () async {
    final r = await readSecretCli({'SECRETS_PASS': key});
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    expect(r.stdout, 'hello');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('an empty SECRETS_PASS in the environment falls back to .env',
      () async {
    final r = await readSecretCli({'SECRETS_PASS': ''});
    expect(r.exitCode, isNot(0));
    expect('${r.stdout}${r.stderr}', contains('SecretKeyMismatch'));
    expect('${r.stdout}${r.stderr}',
        contains('the given key is not a generated files key'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
