import 'package:args/args.dart';
import 'package:dotenv/dotenv.dart';
import 'package:test/test.dart';

import '../bin/commands/utils.dart';

void main() {
  const expectedMessage = 'No SSH key configured. Set SSH_KEY in .env or the '
      'environment, or pass --ssh-key=<name>.';
  const requiredNameMessage = 'No SSH key configured. Set SSH_KEY in .env or '
      'the environment, or pass --ssh-key=<name>. This command gives the key '
      'name to the cloud provider.';

  /// The parsed arguments of a parent command that declares --ssh-key, like
  /// fleet, cluster, etcd and registry.
  ArgResults parentArgs(List<String> args) =>
      (ArgParser()
            ..addOption('working-dir', abbr: 'd', defaultsTo: '.')
            ..addOption('ssh-key')
            ..addOption('env'))
          .parse(args);

  /// DotEnv() does not include the platform environment, so a SSH_KEY of
  /// the developer's shell does not leak into these tests.
  DotEnv envOf(Map<String, String> values) => DotEnv()..addAll(values);

  final throwsNoKeyConfigured = throwsA(isA<Exception>()
      .having((e) => e.toString(), 'toString()', 'Exception: $expectedMessage'));

  group('resolveSshKeyName', () {
    test('--ssh-key gives the name', () {
      expect(
          resolveSshKeyName(parentArgs(['--ssh-key=from-option']), envOf({})),
          'from-option');
    });

    test('SSH_KEY gives the name when --ssh-key is not given', () {
      expect(resolveSshKeyName(parentArgs([]), envOf({'SSH_KEY': 'from-env'})),
          'from-env');
    });

    test('--ssh-key wins over SSH_KEY', () {
      expect(
          resolveSshKeyName(parentArgs(['--ssh-key=from-option']),
              envOf({'SSH_KEY': 'from-env'})),
          'from-option');
    });

    test('an empty --ssh-key falls back to SSH_KEY', () {
      expect(
          resolveSshKeyName(
              parentArgs(['--ssh-key=']), envOf({'SSH_KEY': 'from-env'})),
          'from-env');
    });

    test('no --ssh-key and no SSH_KEY throws a readable Exception', () {
      expect(() => resolveSshKeyName(parentArgs([]), envOf({})),
          throwsNoKeyConfigured);
    });

    test('no --ssh-key and an empty SSH_KEY throws', () {
      expect(() => resolveSshKeyName(parentArgs([]), envOf({'SSH_KEY': ''})),
          throwsA(isA<Exception>().having(
              (e) => e.toString(),
              'toString()',
              allOf(contains('SSH_KEY'), contains('--ssh-key')))));
    });

    test('an empty --ssh-key and an empty SSH_KEY throws', () {
      expect(
          () => resolveSshKeyName(
              parentArgs(['--ssh-key=']), envOf({'SSH_KEY': ''})),
          throwsNoKeyConfigured);
    });

    test('a null parentArgs reads SSH_KEY', () {
      expect(resolveSshKeyName(null, envOf({'SSH_KEY': 'from-env'})),
          'from-env');
    });

    test('a null parentArgs and no SSH_KEY throws', () {
      expect(() => resolveSshKeyName(null, envOf({})), throwsNoKeyConfigured);
    });

    test('a parent without an ssh-key option reads SSH_KEY', () {
      final noSshKeyOption =
          (ArgParser()..addOption('working-dir', abbr: 'd')).parse([]);
      expect(
          resolveSshKeyName(noSshKeyOption, envOf({'SSH_KEY': 'from-env'})),
          'from-env');
    });

    test('a parent without an ssh-key option and no SSH_KEY throws '
        'the readable Exception, not an ArgumentError', () {
      final noSshKeyOption =
          (ArgParser()..addOption('working-dir', abbr: 'd')).parse([]);
      expect(() => resolveSshKeyName(noSshKeyOption, envOf({})),
          throwsNoKeyConfigured);
    });

    test('requireName gives the name of the option or SSH_KEY', () {
      expect(
          resolveSshKeyName(parentArgs(['--ssh-key=from-option']), envOf({}),
              requireName: true),
          'from-option');
      expect(
          resolveSshKeyName(parentArgs([]), envOf({'SSH_KEY': 'from-env'}),
              requireName: true),
          'from-env');
    });

    test('requireName and no name throws the message for a required name',
        () {
      expect(
          () => resolveSshKeyName(parentArgs([]), envOf({}), requireName: true),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              'Exception: $requiredNameMessage')));
    });
  });

  group('resolveSshKeyName: the missing-name message', () {
    test('names SSH_KEY and --ssh-key, and nothing else', () {
      expect(
          () => resolveSshKeyName(parentArgs([]), envOf({})),
          throwsA(isA<Exception>().having(
              (e) => e.toString(),
              'toString()',
              allOf(contains('SSH_KEY in .env'), contains('--ssh-key=<name>'),
                  isNot(contains('private key file')),
                  isNot(contains('alone is not enough'))))));
    });
  });

  group('resolveSshKeyName with SSH_KEY_MAP_PATH', () {
    test('a key map and no name gives an empty name', () {
      expect(
          resolveSshKeyName(
              parentArgs([]), envOf({'SSH_KEY_MAP_PATH': '/keys/map.json'})),
          '');
      expect(
          resolveSshKeyName(null, envOf({'SSH_KEY_MAP_PATH': 'map.json'})),
          '');
    });

    test('a name wins over the key map', () {
      expect(
          resolveSshKeyName(parentArgs([]),
              envOf({'SSH_KEY': 'from-env', 'SSH_KEY_MAP_PATH': 'map.json'})),
          'from-env');
      expect(
          resolveSshKeyName(parentArgs(['--ssh-key=from-option']),
              envOf({'SSH_KEY_MAP_PATH': 'map.json'})),
          'from-option');
    });

    test('an empty or blank SSH_KEY_MAP_PATH counts as not set', () {
      expect(
          () => resolveSshKeyName(
              parentArgs([]), envOf({'SSH_KEY_MAP_PATH': ''})),
          throwsNoKeyConfigured);
      expect(
          () => resolveSshKeyName(
              parentArgs([]), envOf({'SSH_KEY_MAP_PATH': '  '})),
          throwsNoKeyConfigured);
    });

    test('SSH_AUTH_SOCK alone does not replace the name', () {
      expect(
          () => resolveSshKeyName(
              parentArgs([]), envOf({'SSH_AUTH_SOCK': '/tmp/agent.sock'})),
          throwsNoKeyConfigured);
    });

    test('requireName and a key map without a name still throws', () {
      expect(
          () => resolveSshKeyName(
              parentArgs([]), envOf({'SSH_KEY_MAP_PATH': '/keys/map.json'}),
              requireName: true),
          throwsA(isA<Exception>().having((e) => e.toString(), 'toString()',
              'Exception: $requiredNameMessage')));
    });
  });
}
