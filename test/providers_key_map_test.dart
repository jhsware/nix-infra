// The key source of each machine (docs/design/ssh_agent_keys.md §3, §4):
// the order of §4.2 in keySourceFor, and the providers that read the key map
// of SSH_KEY_MAP_PATH at each listing. Nothing here connects.
import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/ssh_key_map.dart';
import 'package:nix_infra/types.dart';
import 'package:test/test.dart';

const fpWeb = 'SHA256:u2l0c8QfR1vN0mJ5rT8hD4kX9aYb3Wq7eZs6PpLo1Hg';
const fpDefault = 'SHA256:Yk0nDTpL0dQ4Jw0b4QnP3o1bq0oT1dS6r0Qe2m9uJ3c';
const fpOther = 'SHA256:0ther0ther0ther0ther0ther0ther0ther0ther0th';
const socket = '/run/test-agent/agent.sock';

/// Three servers of the Hetzner API (`GET /v1/servers`).
const apiServers = [
  {
    'name': 'web-1',
    'id': 1,
    'public_net': {
      'ipv4': {'ip': '203.0.113.1'}
    },
  },
  {
    'name': 'db-1',
    'id': 2,
    'public_net': {
      'ipv4': {'ip': '203.0.113.2'}
    },
  },
  {
    'name': 'app-1',
    'id': 3,
    'public_net': {
      'ipv4': {'ip': '203.0.113.3'}
    },
  },
];

/// The key map of design §4.1: web-1 by name, db-1 unavailable, every other
/// machine by `default` (left out when [withDefault] is false).
Map<String, dynamic> designMap({bool withDefault = true}) => {
      'version': 1,
      if (withDefault) 'default': {'agent_key': fpDefault},
      'nodes': {
        'web-1': {'agent_key': fpWeb},
        'db-1': {'unavailable': 'secrets_locked', 'ring': 'interactive'},
      },
    };

/// Lists the machines of a provider again at each call, by name.
typedef Lister = Future<Map<String, ClusterNode>> Function();

void main() {
  late Directory dir;
  late String mapPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_key_map_providers_');
    mapPath = '${dir.path}/key_map.json';
    File('${dir.path}/servers.yaml').writeAsStringSync('''
servers:
  web-1:
    ip: 192.0.2.1
    ssh_key: ./ssh/web-key
  db-1:
    ip: 192.0.2.2
    ssh_key: /opt/keys/db-key
  app-1:
    ip: 192.0.2.3
    ssh_key: ./ssh/app-key
''');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void writeMap(Map<String, dynamic> json) =>
      File(mapPath).writeAsStringSync(jsonEncode(json));

  group('keySourceFor (design §4.2)', () {
    const map = SshKeyMap(
      defaultEntry: AgentKeyEntry(fpDefault),
      nodes: {
        'web-1': AgentKeyEntry(fpWeb),
        'db-1': UnavailableEntry('secrets_locked', ring: 'interactive'),
        'db-2': UnavailableEntry('maintenance'),
      },
    );

    test('no key map: a key file (rules 3 and 4 decide)', () {
      expect(keySourceFor(null, 'web-1', agentSocket: socket),
          const KeyFileSource());
    });

    test('rule 1: nodes[<name>] gives its agent key and the socket', () {
      expect(keySourceFor(map, 'web-1', agentSocket: socket),
          const AgentKeySource(fpWeb, agentSocket: socket));
    });

    test('rule 2: a machine that nodes does not name gets default', () {
      expect(keySourceFor(map, 'app-1', agentSocket: socket),
          const AgentKeySource(fpDefault, agentSocket: socket));
    });

    test('an unavailable entry of nodes wins over default (no fall-through)',
        () {
      expect(keySourceFor(map, 'db-1', agentSocket: socket),
          const UnavailableKeySource('secrets_locked, ring interactive'));
      expect(keySourceFor(map, 'db-2', agentSocket: socket),
          const UnavailableKeySource('maintenance'));
    });

    test('an unavailable default: no fall-through to the key file', () {
      const unavailableDefault =
          SshKeyMap(defaultEntry: UnavailableEntry('secrets_locked'));
      expect(keySourceFor(unavailableDefault, 'app-1'),
          const UnavailableKeySource('secrets_locked'));
    });

    test('without default a machine that nodes does not name uses a key file',
        () {
      const noDefault = SshKeyMap(nodes: {'web-1': AgentKeyEntry(fpWeb)});
      expect(keySourceFor(noDefault, 'app-1', agentSocket: socket),
          const KeyFileSource());
    });

    test('the name is compared exactly', () {
      expect(keySourceFor(map, 'Web-1', agentSocket: socket),
          const AgentKeySource(fpDefault, agentSocket: socket));
    });

    test('without SSH_AUTH_SOCK the agent key source has no socket', () {
      expect(keySourceFor(map, 'web-1'), const AgentKeySource(fpWeb));
    });

    test('the toString of an agent key source does not show the socket', () {
      expect(const AgentKeySource(fpWeb, agentSocket: socket).toString(),
          isNot(contains(socket)));
    });
  });

  group('keySourcesForListing', () {
    test('no key map path: a key file for every machine', () {
      final sourceOf = keySourcesForListing(null, agentSocket: socket);
      expect(sourceOf('web-1'), const KeyFileSource());
    });

    test('reads the key map at each call, never later', () {
      writeMap(designMap());
      final first = keySourcesForListing(mapPath, agentSocket: socket);
      writeMap({
        'version': 1,
        'nodes': {
          'web-1': {'agent_key': fpOther},
        },
      });
      final second = keySourcesForListing(mapPath, agentSocket: socket);

      expect(first('web-1'), const AgentKeySource(fpWeb, agentSocket: socket));
      expect(second('web-1'),
          const AgentKeySource(fpOther, agentSocket: socket));
    });

    for (final (what, content) in [
      ('a missing key map', null),
      ('a key map that is not JSON', '{"version": 1,'),
      ('a key map of another version', '{"version": 2}'),
    ]) {
      test('$what: every machine has an unreadable key map, without its path',
          () {
        if (content != null) File(mapPath).writeAsStringSync(content);
        final sourceOf = keySourcesForListing(mapPath, agentSocket: socket);
        for (final name in ['web-1', 'app-1']) {
          final source = sourceOf(name);
          expect(source, isA<KeyMapUnreadableSource>());
          final detail = (source as KeyMapUnreadableSource).detail;
          expect(detail, startsWith('The key map '));
          expect(detail, isNot(contains(dir.path)));
          expect(source.toString(), isNot(contains(dir.path)));
        }
      });
    }
  });

  for (final kind in ['SelfHosting', 'HetznerCloud']) {
    group('$kind: the key source of each listed machine', () {
      /// A provider of [kind] in [dir]; each call of the result lists again.
      Future<Lister> lister({String? keyMapPath, String? agentSocket}) async {
        if (kind == 'SelfHosting') {
          final provider = await SelfHosting.load(dir,
              sshKeyMapPath: keyMapPath, sshAgentSocket: agentSocket);
          return () async =>
              {for (final node in await provider.getServers()) node.name: node};
        }
        final provider = HetznerCloud(
            token: 'test-token',
            sshKey: 'my-key',
            sshKeyMapPath: keyMapPath,
            sshAgentSocket: agentSocket);
        return () async => {
              for (final node in provider.nodesFromApiServers(apiServers))
                node.name: node
            };
      }

      /// The key file of app-1 without a key map: rule 3 (`ssh_key` of
      /// servers.yaml) for SelfHosting, rule 4 (`ssh/<SSH_KEY>`) for
      /// HetznerCloud.
      String appKeyFile() => kind == 'SelfHosting'
          ? '${dir.path}/ssh/app-key'
          : '${dir.path}/ssh/my-key';

      test('rule 1 and 2: named in nodes gets its key, the others default',
          () async {
        writeMap(designMap());
        final nodes = await (await lister(
            keyMapPath: mapPath, agentSocket: socket))();

        expect(nodes['web-1']!.keySource,
            const AgentKeySource(fpWeb, agentSocket: socket));
        expect(nodes['app-1']!.keySource,
            const AgentKeySource(fpDefault, agentSocket: socket));
      });

      test('an unavailable entry, with its ring', () async {
        writeMap(designMap());
        final nodes = await (await lister(
            keyMapPath: mapPath, agentSocket: socket))();

        expect(nodes['db-1']!.keySource,
            const UnavailableKeySource('secrets_locked, ring interactive'));
      });

      test('rule 3 and 4: without default a machine not named keeps its key '
          'file', () async {
        writeMap(designMap(withDefault: false));
        final nodes = await (await lister(
            keyMapPath: mapPath, agentSocket: socket))();

        final app = nodes['app-1']!;
        expect(app.keySource, const KeyFileSource());
        expect(app.getEffectiveSshKeyPath(dir.path), appKeyFile());
        expect(nodes['web-1']!.keySource,
            const AgentKeySource(fpWeb, agentSocket: socket));
      });

      test('a key map written again between two listings is seen', () async {
        writeMap(designMap());
        final list = await lister(keyMapPath: mapPath, agentSocket: socket);
        final before = await list();
        writeMap({
          'version': 1,
          'default': {'agent_key': fpOther},
        });
        final after = await list();

        expect(before['web-1']!.keySource,
            const AgentKeySource(fpWeb, agentSocket: socket));
        for (final name in ['web-1', 'db-1', 'app-1']) {
          expect(after[name]!.keySource,
              const AgentKeySource(fpOther, agentSocket: socket),
              reason: name);
        }
      });

      test('a key map deleted between two listings: every machine is '
          'unavailable, and the listing does not fail', () async {
        writeMap(designMap());
        final list = await lister(keyMapPath: mapPath, agentSocket: socket);
        await list();
        File(mapPath).deleteSync();
        final after = await list();

        expect(after.keys.toSet(), {'web-1', 'db-1', 'app-1'});
        for (final node in after.values) {
          expect(node.keySource,
              const KeyMapUnreadableSource('The key map cannot be read.'),
              reason: node.name);
        }
      });

      test('without the key map path nothing changes', () async {
        writeMap(designMap());
        final nodes = await (await lister(agentSocket: socket))();

        for (final node in nodes.values) {
          expect(node.keySource, const KeyFileSource(), reason: node.name);
        }
        expect(nodes['app-1']!.getEffectiveSshKeyPath(dir.path), appKeyFile());
      });
    });
  }

  test('SelfHosting: getServers(only:) sets the key source too', () async {
    writeMap(designMap());
    final provider = await SelfHosting.load(dir,
        sshKeyMapPath: mapPath, sshAgentSocket: socket);
    final nodes = (await provider.getServers(only: ['web-1'])).toList();

    expect(nodes.single.keySource,
        const AgentKeySource(fpWeb, agentSocket: socket));
  });

  group('ProviderFactory.autoDetect', () {
    /// DotEnv() does not include the platform environment.
    DotEnv envOf(Map<String, String> values) => DotEnv()..addAll(values);

    test('passes the key map and the socket to SelfHosting', () async {
      writeMap(designMap());
      final provider = await ProviderFactory.autoDetect(
        workingDir: dir,
        env: envOf({}),
        sshKeyName: '',
        sshKeyMapPath: mapPath,
        sshAgentSocket: socket,
      );
      final nodes = {
        for (final node in await provider.getServers()) node.name: node
      };

      expect(nodes['web-1']!.keySource,
          const AgentKeySource(fpWeb, agentSocket: socket));
      expect(nodes['db-1']!.keySource, isA<UnavailableKeySource>());
    });

    test('passes the key map and the socket to HetznerCloud', () async {
      writeMap(designMap());
      File('${dir.path}/servers.yaml').deleteSync();
      final provider = await ProviderFactory.autoDetect(
        workingDir: dir,
        env: envOf({'HCLOUD_TOKEN': 'test-token'}),
        sshKeyName: '',
        sshKeyMapPath: mapPath,
        sshAgentSocket: socket,
      );

      expect(provider, isA<HetznerCloud>());
      final nodes = (provider as HetznerCloud).nodesFromApiServers(apiServers);
      expect(nodes.first.keySource,
          const AgentKeySource(fpWeb, agentSocket: socket));
    });

    test('reads neither SSH_KEY_MAP_PATH nor SSH_AUTH_SOCK of env', () async {
      writeMap(designMap());
      final provider = await ProviderFactory.autoDetect(
        workingDir: dir,
        env: envOf({kSshKeyMapPathEnv: mapPath, kSshAuthSockEnv: socket}),
        sshKeyName: 'key',
      );

      for (final node in await provider.getServers()) {
        expect(node.keySource, const KeyFileSource(), reason: node.name);
      }
    });
  });
}
