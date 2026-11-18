// The key map of lib/ssh_key_map.dart (docs/design/ssh_agent_keys.md §4.1,
// §4.2): every rule of the schema, the lookup of one machine, and the path
// of SSH_KEY_MAP_PATH.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/ssh_key_map.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const fpDefault = 'SHA256:Yk0nDTpL0dQ4Jw0b4QnP3o1bq0oT1dS6r0Qe2m9uJ3c';
const fpWeb = 'SHA256:u2l0c8QfR1vN0mJ5rT8hD4kX9aYb3Wq7eZs6PpLo1Hg';

/// The example of design §4.1.
const designExample = '''
{
  "version": 1,
  "default": { "agent_key": "$fpDefault" },
  "nodes": {
    "web-1": { "agent_key": "$fpWeb" },
    "db-1":  { "unavailable": "secrets_locked", "ring": "interactive" }
  }
}
''';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('nix_infra_keymap_'));

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Writes [content] (a string or bytes) to the key map file in [dir].
  String write(Object content) {
    final file = File(p.join(dir.path, 'key_map.json'));
    if (content is String) {
      file.writeAsStringSync(content);
    } else {
      file.writeAsBytesSync(content as List<int>);
    }
    return file.path;
  }

  SshKeyMap load(Object? json) => loadSshKeyMap(write(jsonEncode(json)));

  /// An [SshKeyMapException] for [path] whose message matches [message] and
  /// whose texts hold nothing of the path (design §7).
  Matcher keyMapError(String path, Object message) => isA<SshKeyMapException>()
      .having((e) => e.path, 'path', path)
      .having((e) => e.message, 'message', message)
      .having((e) => e.message, 'message', isNot(contains(dir.path)))
      .having((e) => e.message, 'message', isNot(contains('key_map.json')))
      .having((e) => e.toString(), 'toString()', isNot(contains(dir.path)))
      .having((e) => e.toString(), 'toString()',
          isNot(contains('key_map.json')));

  /// Loading [json] fails with a message that matches [message].
  void expectInvalid(Object? json, Object message) {
    final path = write(jsonEncode(json));
    expect(() => loadSshKeyMap(path), throwsA(keyMapError(path, message)));
  }

  group('the schema', () {
    test('the example of the design', () {
      final map = loadSshKeyMap(write(designExample));
      expect(map.defaultEntry, const AgentKeyEntry(fpDefault));
      expect(map.nodes, {
        'web-1': const AgentKeyEntry(fpWeb),
        'db-1': const UnavailableEntry('secrets_locked', ring: 'interactive'),
      });
      expect(map.entryFor('web-1'), const AgentKeyEntry(fpWeb));
      expect(map.entryFor('db-1'),
          const UnavailableEntry('secrets_locked', ring: 'interactive'));
      expect(map.entryFor('other'), const AgentKeyEntry(fpDefault));
    });

    test('only default', () {
      final map = load({
        'version': 1,
        'default': {'agent_key': fpDefault},
      });
      expect(map.nodes, isEmpty);
      expect(map.entryFor('web-1'), const AgentKeyEntry(fpDefault));
    });

    test('only nodes', () {
      final map = load({
        'version': 1,
        'nodes': {
          'web-1': {'agent_key': fpWeb},
        },
      });
      expect(map.defaultEntry, isNull);
      expect(map.entryFor('web-1'), const AgentKeyEntry(fpWeb));
      expect(map.entryFor('web-2'), isNull);
    });

    test('neither: valid, and every lookup is null', () {
      final map = load({'version': 1});
      expect(map.defaultEntry, isNull);
      expect(map.nodes, isEmpty);
      expect(map.entryFor('web-1'), isNull);
      expect(map.entryFor(''), isNull);
    });

    test('unavailable with and without ring', () {
      final map = load({
        'version': 1,
        'default': {'unavailable': 'no_key'},
        'nodes': {
          'db-1': {'unavailable': 'secrets_locked', 'ring': 'interactive'},
        },
      });
      expect(map.defaultEntry, const UnavailableEntry('no_key'));
      expect((map.defaultEntry as UnavailableEntry).ring, isNull);
      expect(map.entryFor('db-1'),
          const UnavailableEntry('secrets_locked', ring: 'interactive'));
    });

    test('unknown fields are ignored at every level', () {
      final map = load({
        'version': 1,
        'comment': 'made by sysops',
        'future': {'nested': true},
        'default': {'agent_key': fpDefault, 'note': 1, 'ring': 'ignored'},
        'nodes': {
          'web-1': {'agent_key': fpWeb, 'added': '2026-11-18'},
          'db-1': {'unavailable': 'locked', 'ring': 'r', 'since': null},
        },
      });
      expect(map.defaultEntry, const AgentKeyEntry(fpDefault));
      expect(map.nodes, {
        'web-1': const AgentKeyEntry(fpWeb),
        'db-1': const UnavailableEntry('locked', ring: 'r'),
      });
    });

    test('version 1.0 is the number 1', () {
      expect(load({'version': 1.0}).nodes, isEmpty);
    });

    test('the file is read at each call', () {
      final path = write(jsonEncode({'version': 1}));
      expect(loadSshKeyMap(path).defaultEntry, isNull);
      write(jsonEncode({
        'version': 1,
        'default': {'agent_key': fpDefault},
      }));
      expect(loadSshKeyMap(path).defaultEntry, const AgentKeyEntry(fpDefault));
    });
  });

  group('entryFor', () {
    final map = SshKeyMap(defaultEntry: const AgentKeyEntry(fpDefault), nodes: {
      'web-1': const AgentKeyEntry(fpWeb),
      'web-*': const UnavailableEntry('pattern'),
    });

    test('a node entry wins over default; another node gets default', () {
      expect(map.entryFor('web-1'), const AgentKeyEntry(fpWeb));
      expect(map.entryFor('db-1'), const AgentKeyEntry(fpDefault));
    });

    test('without default: null for a node without entry', () {
      final noDefault = SshKeyMap(nodes: map.nodes);
      expect(noDefault.entryFor('web-1'), const AgentKeyEntry(fpWeb));
      expect(noDefault.entryFor('db-1'), isNull);
    });

    test('names are compared exactly; there are no patterns', () {
      expect(map.entryFor('Web-1'), const AgentKeyEntry(fpDefault));
      expect(map.entryFor('web-1 '), const AgentKeyEntry(fpDefault));
      expect(map.entryFor('web-2'), const AgentKeyEntry(fpDefault));
      expect(map.entryFor('web-*'), const UnavailableEntry('pattern'));
    });
  });

  group('errors', () {
    test('version missing, 2, "1", null', () {
      expectInvalid({}, contains('no "version"'));
      expectInvalid({'version': 2}, contains('version 2;'));
      expectInvalid({'version': '1'}, contains('version "1";'));
      expectInvalid({'version': null}, contains('version null;'));
      expectInvalid({'version': 1.5}, contains('version 1.5;'));
    });

    test('not a JSON object', () {
      expectInvalid([], 'The key map is not a JSON object.');
      expectInvalid('text', 'The key map is not a JSON object.');
      expectInvalid(null, 'The key map is not a JSON object.');
    });

    test('invalid JSON', () {
      for (final content in <Object>['{"version": 1', '', [0xff, 0xfe]]) {
        final path = write(content);
        expect(() => loadSshKeyMap(path),
            throwsA(keyMapError(path, 'The key map is not valid JSON.')));
      }
    });

    test('a missing file, and a folder', () {
      for (final path in [p.join(dir.path, 'key_map.json'), dir.path]) {
        expect(() => loadSshKeyMap(path),
            throwsA(keyMapError(path, 'The key map cannot be read.')));
      }
    });

    test('default or nodes that is not an object', () {
      expectInvalid({'version': 1, 'default': 'SHA256:x'},
          contains('entry of "default" is not a JSON object'));
      expectInvalid({'version': 1, 'default': null},
          contains('entry of "default" is not a JSON object'));
      expectInvalid({'version': 1, 'nodes': []},
          contains('"nodes" of the key map is not a JSON object'));
    });

    test('an entry with both, with neither, or a number', () {
      Map<String, Object?> node(Object? entry) => {
            'version': 1,
            'nodes': {'web-1': entry},
          };
      const either = 'must have either "agent_key" or "unavailable"';
      expectInvalid(
          node({'agent_key': fpWeb, 'unavailable': 'locked'}),
          allOf(contains('machine "web-1"'), contains(either)));
      expectInvalid(node({}), allOf(contains('machine "web-1"'), contains(either)));
      expectInvalid(node({'ring': 'interactive'}), contains(either));
      expectInvalid(
          node(5), contains('entry of machine "web-1" is not a JSON object'));
      expectInvalid({
        'version': 1,
        'default': {'agent_key': fpDefault, 'unavailable': 'x'},
      }, allOf(contains('"default"'), contains(either)));
    });

    test('a field of the wrong type', () {
      Map<String, Object?> node(Map<String, Object?> entry) => {
            'version': 1,
            'nodes': {'db-1': entry},
          };
      for (final (entry, field) in [
        ({'agent_key': 1}, 'agent_key'),
        ({'agent_key': ''}, 'agent_key'),
        ({'agent_key': '  '}, 'agent_key'),
        ({'agent_key': null}, 'agent_key'),
        ({'unavailable': true}, 'unavailable'),
        ({'unavailable': ''}, 'unavailable'),
      ]) {
        expectInvalid(
            node(entry),
            '"$field" of the key map entry of machine "db-1" is not a '
            'non-empty string.');
      }
      for (final ring in [3, null, ['interactive']]) {
        expectInvalid(node({'unavailable': 'locked', 'ring': ring}),
            '"ring" of the key map entry of machine "db-1" is not a string.');
      }
    });
  });

  group('resolveSshKeyMapPath', () {
    DotEnv envOf(Map<String, String> values) => DotEnv()..addAll(values);
    final project = Directory('/projects/fleet');

    test('unset, empty or blank: null', () {
      expect(resolveSshKeyMapPath(envOf({}), project), isNull);
      expect(resolveSshKeyMapPath(envOf({kSshKeyMapPathEnv: ''}), project),
          isNull);
      expect(resolveSshKeyMapPath(envOf({kSshKeyMapPathEnv: '  '}), project),
          isNull);
    });

    test('an absolute path as it is, normalized', () {
      expect(
          resolveSshKeyMapPath(
              envOf({kSshKeyMapPathEnv: ' /run/sysops/../keys/map.json '}),
              project),
          '/run/keys/map.json');
    });

    test('a relative path is relative to the project folder', () {
      String? resolve(String value) =>
          resolveSshKeyMapPath(envOf({kSshKeyMapPathEnv: value}), project);
      expect(resolve('key_map.json'), '/projects/fleet/key_map.json');
      expect(resolve('./ssh/map.json'), '/projects/fleet/ssh/map.json');
      expect(resolve('../shared/map.json'), '/projects/shared/map.json');
      // No ~/ rule: the design names only absolute and relative paths.
      expect(resolve('~/map.json'), '/projects/fleet/~/map.json');
    });

    test('a relative project folder is made absolute', () {
      final path = resolveSshKeyMapPath(
          envOf({kSshKeyMapPathEnv: 'map.json'}), Directory('fleet'));
      expect(p.isAbsolute(path!), isTrue);
      expect(path, p.join(Directory.current.path, 'fleet', 'map.json'));
    });

    test('the file is not checked', () {
      expect(
          resolveSshKeyMapPath(
              envOf({kSshKeyMapPathEnv: '/does/not/exist.json'}), project),
          '/does/not/exist.json');
    });
  });
}
