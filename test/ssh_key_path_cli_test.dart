import 'dart:async';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/ssh_identity.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../bin/commands/shared.dart';
import '../bin/commands/utils.dart';

// SSH_KEY_PATH was removed with no transition (docs/design/ssh_agent_keys.md
// §8): nix-infra no longer knows the name. A set SSH_KEY_PATH has no effect
// and gives no error and no warning, as in every released nix-infra. This
// is the only file in lib/, bin/ and test/ that names SSH_KEY_PATH: it
// proves that a caller who still sets it gets the key of `ssh_key` in
// servers.yaml or of `ssh/<SSH_KEY>`, or else the error for a missing key
// name, with the same text as without the variable.
//
// The unit tests follow the CLI path from the configuration to the key:
// loadEnv, resolveSshKeyName, getProvider and publicKeyOf. The process tests
// run the real CLI entry point (it compiles nix-infra once per run). No test
// connects to a machine.

const _variable = 'SSH_KEY_PATH';

const _web001PublicKey = 'ssh-ed25519 AAAAweb001 web001@project';
const _testKeyPublicKey = 'ssh-ed25519 AAAAtestkey test-key@project';
const _otherPublicKey = 'ssh-ed25519 AAAAother other@elsewhere';

const _missingKeyNameError = 'Exception: No SSH key configured. Set SSH_KEY '
    'in .env or the environment, or pass --ssh-key=<name>.';

/// Collects what is written to stdout or stderr inside
/// [IOOverrides.runZoned].
class _CapturingStdout implements Stdout {
  final buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Runs [body] and returns its result and everything it wrote to stdout,
/// stderr and `print`.
Future<(T, String)> _captureOutput<T>(Future<T> Function() body) async {
  final out = _CapturingStdout();
  final err = _CapturingStdout();
  final printed = StringBuffer();
  final result = await runZoned(
      () => IOOverrides.runZoned(body, stdout: () => out, stderr: () => err),
      zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.writeln(line)));
  return (result, '${out.buffer}${err.buffer}$printed');
}

/// The text of the Exception that [f] throws.
String _errorOf(void Function() f) {
  try {
    f();
  } on Exception catch (e) {
    return e.toString();
  }
  throw StateError('no Exception was thrown');
}

/// A project folder with the key files `ssh/web001` (the `ssh_key` of
/// servers.yaml) and `ssh/test-key` (the key of `SSH_KEY=test-key`), and
/// another key outside `ssh/`: `other/id_other`, the key that SSH_KEY_PATH
/// names. Each key has its `.pub` file, unless [testKeyPub] is false.
/// With [servers] the project has a servers.yaml with one machine on an
/// address of TEST-NET-1 (RFC 5737), never reached.
Directory _project({required bool servers, bool testKeyPub = true}) {
  final dir = Directory.systemTemp.createTempSync('nix_infra_no_key_path_');
  void key(String name, String? publicKey) {
    File('${dir.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync('not read by these tests');
    if (publicKey != null) {
      File('${dir.path}/$name.pub').writeAsStringSync('$publicKey\n');
    }
  }

  key('ssh/web001', _web001PublicKey);
  key('ssh/test-key', testKeyPub ? _testKeyPublicKey : null);
  key('other/id_other', _otherPublicKey);
  if (servers) {
    File('${dir.path}/servers.yaml').writeAsStringSync('''
servers:
  web001:
    ip: 192.0.2.10
    ssh_key: ./ssh/web001
''');
  }
  return dir;
}

/// The value of SSH_KEY_PATH: the other key, or a file that does not exist.
String _keyPathValue(Directory dir, {required bool existing}) => existing
    ? '${dir.path}/other/id_other'
    : '${dir.path}/other/does-not-exist';

/// The configuration of a CLI command in [dir]: [dotEnv] in `.env`, and
/// SSH_KEY_PATH=[keyPath] in `.env` ([inDotEnv]) or in the process
/// environment. No other variable of the process environment is read.
Future<DotEnv> _envWith(Directory dir, Map<String, String> dotEnv,
    {required String keyPath, required bool inDotEnv}) {
  final lines = {...dotEnv, if (inDotEnv) _variable: keyPath};
  File('${dir.path}/.env').writeAsStringSync(
      lines.entries.map((e) => '${e.key}=${e.value}\n').join());
  return loadEnv(null, dir,
      processEnvironment: {if (!inDotEnv) _variable: keyPath});
}

void main() {
  final apiServer = {
    'name': 'web001',
    'id': 42,
    'public_net': {
      'ipv4': {'ip': '192.0.2.10'},
    },
  };

  for (final inDotEnv in [true, false]) {
    for (final existing in [true, false]) {
      final where = inDotEnv ? 'in .env' : 'in the process environment';
      final file = existing ? 'an existing file' : 'a missing file';

      group('$_variable $where naming $file', () {
        final dirs = <Directory>[];
        Directory project({required bool servers, bool testKeyPub = true}) {
          final dir = _project(servers: servers, testKeyPub: testKeyPub);
          dirs.add(dir);
          return dir;
        }

        tearDown(() {
          for (final dir in dirs) {
            if (dir.existsSync()) dir.deleteSync(recursive: true);
          }
          dirs.clear();
        });

        test('servers.yaml: the machine uses its ssh_key', () async {
          final dir = project(servers: true);
          final keyPath = _keyPathValue(dir, existing: existing);

          final (result, output) = await _captureOutput(() async {
            final env = await _envWith(dir, {'SSH_KEY': 'test-key'},
                keyPath: keyPath, inDotEnv: inDotEnv);
            final name = resolveSshKeyName(null, env);
            final provider = await getProvider(dir, env, name);
            final node = (await provider.getServers()).single;
            return (
              value: env[_variable],
              name: name,
              provider: provider,
              node: node,
              publicKey: await publicKeyOf(dir, node),
            );
          });

          expect(result.value, equals(keyPath), reason: 'the variable is set');
          expect(result.name, equals('test-key'));
          expect(result.provider, isA<SelfHosting>());
          expect(result.node.sshKeyPath, equals('./ssh/web001'));
          expect(result.node.getEffectiveSshKeyPath(dir.path),
              equals(path.normalize('${dir.path}/ssh/web001')));
          expect(result.publicKey, equals(_web001PublicKey));
          expect(output, isNot(contains(_variable)));
        });

        test('Hetzner: the machine uses ssh/<SSH_KEY>', () async {
          final dir = project(servers: false);
          final keyPath = _keyPathValue(dir, existing: existing);

          final (result, output) = await _captureOutput(() async {
            final env = await _envWith(
                dir, {'SSH_KEY': 'test-key', 'HCLOUD_TOKEN': 'test-token'},
                keyPath: keyPath, inDotEnv: inDotEnv);
            final name = resolveSshKeyName(null, env);
            final provider =
                (await getProvider(dir, env, name)) as HetznerCloud;
            final node = provider.nodeFromApiServer(apiServer);
            return (
              value: env[_variable],
              node: node,
              publicKey: await publicKeyOf(dir, node),
              registered:
                  await provider.publicKeyForRegistration(dir, 'test-key'),
            );
          });

          expect(result.value, equals(keyPath), reason: 'the variable is set');
          expect(result.node.sshKeyName, equals('test-key'));
          expect(result.node.sshKeyPath, isNull);
          expect(result.node.getEffectiveSshKeyPath(dir.path),
              equals(path.normalize('${dir.path}/ssh/test-key')));
          expect(result.publicKey, equals(_testKeyPublicKey));
          expect(result.registered, equals('$_testKeyPublicKey\n'));
          expect(output, isNot(contains(_variable)));
        });

        test('Hetzner: registration never takes the key of $_variable',
            () async {
          final dir = project(servers: false, testKeyPub: false);
          final env = await _envWith(
              dir, {'SSH_KEY': 'test-key', 'HCLOUD_TOKEN': 'test-token'},
              keyPath: _keyPathValue(dir, existing: existing),
              inDotEnv: inDotEnv);
          final provider = (await getProvider(
              dir, env, resolveSshKeyName(null, env))) as HetznerCloud;

          // ssh/test-key.pub is missing: the same error as without the
          // variable, not the public key of other/id_other.
          await expectLater(provider.publicKeyForRegistration(dir, 'test-key'),
              throwsA(isA<FileSystemException>()));
        });

        test('no key name: the same error as without $_variable', () async {
          final dir = project(servers: true);
          final without = await loadEnv(null, dir, processEnvironment: const {});
          final withVariable = await _envWith(dir, const {},
              keyPath: _keyPathValue(dir, existing: existing),
              inDotEnv: inDotEnv);
          expect(withVariable[_variable], isNotNull);

          final error = _errorOf(() => resolveSshKeyName(null, withVariable));
          expect(error, equals(_errorOf(() => resolveSshKeyName(null, without))));
          expect(error, equals(_missingKeyNameError));

          final requiredNameError = _errorOf(() =>
              resolveSshKeyName(null, withVariable, requireName: true));
          expect(
              requiredNameError,
              equals(_errorOf(
                  () => resolveSshKeyName(null, without, requireName: true))));
          expect(requiredNameError, isNot(contains(_variable)));
        });
      });
    }
  }

  group('the CLI without a key name', () {
    late Directory dir;
    late ProcessResult baseline;

    /// Only what `dart run` needs from the process environment, plus
    /// [extra], so a variable of the developer's shell does not leak in.
    Map<String, String> cleanEnvironment(Map<String, String> extra) {
      const passThrough = ['PATH', 'HOME', 'PUB_CACHE', 'TMPDIR'];
      return {
        for (final name in passThrough)
          if (Platform.environment[name] != null)
            name: Platform.environment[name]!,
        ...extra,
      };
    }

    /// `nix-infra fleet cmd -d <dir> --target=web001 uptime`
    Future<ProcessResult> fleetCmd(Map<String, String> environment) =>
        Process.run(
          Platform.resolvedExecutable,
          [
            'run', '--verbosity=error', 'bin/nix_infra.dart', //
            'fleet', 'cmd', '-d', dir.path, '--target=web001', 'uptime',
          ],
          workingDirectory: Directory.current.path,
          environment: cleanEnvironment(environment),
          includeParentEnvironment: false,
        );

    setUpAll(() async {
      dir = _project(servers: true);
      baseline = await fleetCmd(const {});
    });

    tearDownAll(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    tearDown(() {
      final dotEnv = File('${dir.path}/.env');
      if (dotEnv.existsSync()) dotEnv.deleteSync();
    });

    test('without $_variable: the missing-name error', () {
      final output = '${baseline.stdout}${baseline.stderr}';
      expect(baseline.exitCode, 1, reason: output);
      expect(
          baseline.stdout,
          contains('- ERROR: No SSH key configured. Set SSH_KEY in .env or '
              'the environment, or pass --ssh-key=<name>.'));
    });

    for (final inDotEnv in [true, false]) {
      for (final existing in [true, false]) {
        final where = inDotEnv ? 'in .env' : 'in the environment';
        final file = existing ? 'an existing file' : 'a missing file';

        test('$_variable $where naming $file: the same exit code and output',
            () async {
          final keyPath = _keyPathValue(dir, existing: existing);
          if (inDotEnv) {
            File('${dir.path}/.env').writeAsStringSync('$_variable=$keyPath\n');
          }
          final r = await fleetCmd(inDotEnv ? const {} : {_variable: keyPath});

          expect(r.exitCode, equals(baseline.exitCode),
              reason: '${r.stdout}${r.stderr}');
          expect(r.stdout, equals(baseline.stdout));
          expect(r.stderr, equals(baseline.stderr));
          expect(r.stdout, isNot(contains(_variable)));
          expect(r.stderr, isNot(contains(_variable)));
        });
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}