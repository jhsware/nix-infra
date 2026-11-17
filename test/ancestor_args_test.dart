import 'package:args/command_runner.dart';
import 'package:test/test.dart';

import '../bin/commands/utils.dart';

/// A command group that declares the options of `cluster` and `etcd`.
class _Group extends Command<void> {
  _Group(this.name, List<Command<void>> subcommands) {
    argParser
      ..addOption('working-dir', abbr: 'd', defaultsTo: '.')
      ..addOption('ssh-key')
      ..addOption('env');
    subcommands.forEach(addSubcommand);
  }

  @override
  final String name;

  @override
  String get description => 'Group $name';
}

/// A leaf command that records what [ancestorArgsWithOption] finds.
class _Probe extends Command<void> {
  final Map<String, Object?> seen = {};

  @override
  String get name => 'probe';

  @override
  String get description => 'Records the options of its ancestors';

  @override
  void run() {
    for (final option in ['working-dir', 'ssh-key', 'env', 'not-declared']) {
      seen[option] = ancestorArgsWithOption(this, option)?[option];
    }
  }
}

/// `nix-infra cluster etcd probe` and `nix-infra etcd probe`, like the
/// `etcd` group that is mounted twice. A command has one parent, so each
/// mount has its own instances.
({CommandRunner<void> runner, _Probe nested, _Probe topLevel}) _build() {
  final nested = _Probe();
  final topLevel = _Probe();
  final runner = CommandRunner<void>('nix-infra', 'test')
    ..addCommand(_Group('cluster', [
      _Group('etcd', [nested])
    ]))
    ..addCommand(_Group('etcd', [topLevel]));
  return (runner: runner, nested: nested, topLevel: topLevel);
}

void main() {
  group('ancestorArgsWithOption', () {
    test('options given to the outer group reach the leaf', () async {
      final t = _build();
      await t.runner.run([
        'cluster',
        '-d',
        '/x',
        '--ssh-key=a',
        '--env=e',
        'etcd',
        'probe',
      ]);
      expect(t.nested.seen, {
        'working-dir': '/x',
        'ssh-key': 'a',
        'env': 'e',
        'not-declared': null,
      });
    });

    test('an option given to the inner group wins', () async {
      final t = _build();
      await t.runner.run([
        'cluster',
        '-d',
        '/x',
        '--ssh-key=a',
        'etcd',
        '-d',
        '/y',
        '--ssh-key=b',
        'probe',
      ]);
      expect(t.nested.seen['working-dir'], '/y');
      expect(t.nested.seen['ssh-key'], 'b');
    });

    test('an option written after the leaf goes to the inner group and wins',
        () async {
      final t = _build();
      await t.runner
          .run(['cluster', '--ssh-key=a', 'etcd', 'probe', '--ssh-key=c']);
      expect(t.nested.seen['ssh-key'], 'c');
    });

    test('the outer group gives what the inner group was not given', () async {
      final t = _build();
      await t.runner
          .run(['cluster', '--env=e', 'etcd', '--ssh-key=b', 'probe']);
      expect(t.nested.seen, {
        'working-dir': '.',
        'ssh-key': 'b',
        'env': 'e',
        'not-declared': null,
      });
    });

    test('without options the default of the nearest group applies',
        () async {
      final t = _build();
      await t.runner.run(['cluster', 'etcd', 'probe']);
      expect(t.nested.seen, {
        'working-dir': '.',
        'ssh-key': null,
        'env': null,
        'not-declared': null,
      });
    });

    test('the top-level group works as before', () async {
      final t = _build();
      await t.runner.run(['etcd', '-d', '/y', '--ssh-key=b', 'probe']);
      expect(t.topLevel.seen, {
        'working-dir': '/y',
        'ssh-key': 'b',
        'env': null,
        'not-declared': null,
      });
    });

    test('a command without a parent gives null', () {
      expect(ancestorArgsWithOption(_Probe(), 'ssh-key'), isNull);
    });
  });
}
