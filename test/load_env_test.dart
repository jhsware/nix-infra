import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/helpers.dart';
import 'package:test/test.dart';

/// Collects what is written to stderr inside [IOOverrides.runZoned].
class _CapturingStdout implements Stdout {
  final buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_load_env_test_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void writeEnv(String content, [String name = '.env']) {
    File('${dir.path}/$name').writeAsStringSync(content);
  }

  group('envWithProcessPrecedence', () {
    test('a non-empty process value wins over .env', () {
      writeEnv('SECRETS_PASS=old-password\n');
      final env = envWithProcessPrecedence(File('${dir.path}/.env'),
          processEnvironment: {'SECRETS_PASS': 'nisk1_from_process'});
      expect(env['SECRETS_PASS'], 'nisk1_from_process');
    });

    test('a name only in .env gives the .env value', () {
      writeEnv('HCLOUD_TOKEN=from-dotenv\n');
      final env = envWithProcessPrecedence(File('${dir.path}/.env'),
          processEnvironment: const {});
      expect(env['HCLOUD_TOKEN'], 'from-dotenv');
    });

    test('a name only in the process environment gives the process value',
        () {
      writeEnv('OTHER=x\n');
      final env = envWithProcessPrecedence(File('${dir.path}/.env'),
          processEnvironment: {'SSH_KEY': 'from-process'});
      expect(env['SSH_KEY'], 'from-process');
      expect(env['OTHER'], 'x');
    });

    test('an empty process value does not hide the .env value', () {
      writeEnv('SECRETS_PASS=from-dotenv\n');
      final env = envWithProcessPrecedence(File('${dir.path}/.env'),
          processEnvironment: {'SECRETS_PASS': ''});
      expect(env['SECRETS_PASS'], 'from-dotenv');
    });

    test('an empty process value is kept when .env does not define the name',
        () {
      writeEnv('OTHER=x\n');
      final env = envWithProcessPrecedence(File('${dir.path}/.env'),
          processEnvironment: {'SECRETS_PASS': ''});
      expect(env['SECRETS_PASS'], '');
    });

    test('a missing file gives the process environment only, silently', () {
      final captured = _CapturingStdout();
      late DotEnv env;
      IOOverrides.runZoned(() {
        env = envWithProcessPrecedence(File('${dir.path}/.env'),
            processEnvironment: {'A': '1'});
      }, stderr: () => captured);
      expect(env['A'], '1');
      expect(env['B'], isNull);
      expect(captured.buffer.toString(), isNot(contains('[dotenv]')));

      // Sanity check: a plain DotEnv.load of the missing file does print to
      // the captured stderr, so the assertion above is meaningful.
      final control = _CapturingStdout();
      IOOverrides.runZoned(() {
        DotEnv().load(['${dir.path}/.env']);
      }, stderr: () => control);
      expect(control.buffer.toString(), contains('[dotenv]'));
    });

    test('a null file gives the process environment only', () {
      final env =
          envWithProcessPrecedence(null, processEnvironment: {'A': '1'});
      expect(env['A'], '1');
    });

    test('interpolation inside .env is unchanged', () {
      writeEnv('A=fromfile\nB=\$A\n');
      final env = envWithProcessPrecedence(File('${dir.path}/.env'),
          processEnvironment: {'A': 'fromprocess'});
      expect(env['A'], 'fromprocess');
      expect(env['B'], 'fromfile');
    });

    test('quoted and export-prefixed lines still parse', () {
      writeEnv('export FOO="bar"\nBAZ=\'qux\'\n');
      final env = envWithProcessPrecedence(File('${dir.path}/.env'),
          processEnvironment: const {});
      expect(env['FOO'], 'bar');
      expect(env['BAZ'], 'qux');
    });

    test('defaults to the real process environment', () {
      final env = envWithProcessPrecedence(null);
      final path = Platform.environment['PATH'];
      if (path != null && path.isNotEmpty) expect(env['PATH'], path);
    });
  });

  group('loadEnv', () {
    test('reads <workingDir>/.env by default', () async {
      writeEnv('SSH_KEY=project-key\n');
      final env = await loadEnv(null, dir, processEnvironment: const {});
      expect(env['SSH_KEY'], 'project-key');
    });

    test('resolves a custom file name relative to the working dir', () async {
      writeEnv('SSH_KEY=custom-key\n', 'custom.env');
      writeEnv('SSH_KEY=default-key\n');
      final env =
          await loadEnv('custom.env', dir, processEnvironment: const {});
      expect(env['SSH_KEY'], 'custom-key');
    });

    test('applies the process precedence', () async {
      writeEnv('SECRETS_PASS=old-password\nHCLOUD_TOKEN=from-dotenv\n');
      final env = await loadEnv(null, dir, processEnvironment: {
        'SECRETS_PASS': 'nisk1_from_process',
        'HCLOUD_TOKEN': '',
      });
      expect(env['SECRETS_PASS'], 'nisk1_from_process');
      expect(env['HCLOUD_TOKEN'], 'from-dotenv');
    });

    test('a missing .env gives the process environment only', () async {
      final env = await loadEnv(null, dir, processEnvironment: {'A': '1'});
      expect(env['A'], '1');
      expect(env['SSH_KEY'], isNull);
    });
  });
}
