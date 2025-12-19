import 'dart:io';
import 'package:test/test.dart';
import 'package:nix_infra/types.dart';
import 'package:nix_infra/providers/providers.dart';

void main() {
  group('ClusterNode', () {
    test('getEffectiveSshKeyPath returns standard path when sshKeyPath is null', () {
      final node = ClusterNode('test-node', '192.168.1.1', 1, 'my-key');
      
      expect(
        node.getEffectiveSshKeyPath('/home/user/project'),
        equals('/home/user/project/ssh/my-key'),
      );
    });

    test('getEffectiveSshKeyPath returns absolute sshKeyPath directly', () {
      final node = ClusterNode(
        'test-node', 
        '192.168.1.1', 
        1, 
        'my-key',
        sshKeyPath: '/custom/path/to/key',
      );
      
      expect(
        node.getEffectiveSshKeyPath('/home/user/project'),
        equals('/custom/path/to/key'),
      );
    });

    test('getEffectiveSshKeyPath resolves relative sshKeyPath', () {
      final node = ClusterNode(
        'test-node', 
        '192.168.1.1', 
        1, 
        'my-key',
        sshKeyPath: './ssh/custom-key',
      );
      
      expect(
        node.getEffectiveSshKeyPath('/home/user/project'),
        equals('/home/user/project/ssh/custom-key'),
      );
    });

    test('getEffectiveSshKeyPath resolves relative sshKeyPath without dot prefix', () {
      final node = ClusterNode(
        'test-node', 
        '192.168.1.1', 
        1, 
        'my-key',
        sshKeyPath: 'keys/server-key',
      );
      
      expect(
        node.getEffectiveSshKeyPath('/home/user/project'),
        equals('/home/user/project/keys/server-key'),
      );
    });

    test('default username is root', () {
      final node = ClusterNode('test-node', '192.168.1.1', 1, 'my-key');
      expect(node.username, equals('root'));
    });

    test('username can be changed', () {
      final node = ClusterNode('test-node', '192.168.1.1', 1, 'my-key');
      node.username = 'admin';
      expect(node.username, equals('admin'));
    });
  });

  group('SelfHostedServerConfig', () {
    test('fromYaml parses minimal config', () {
      final yaml = {
        'ip': '192.168.1.10',
        'ssh_key': './ssh/server-key',
      };
      
      final config = SelfHostedServerConfig.fromYaml('test-server', yaml);
      
      expect(config.name, equals('test-server'));
      expect(config.ipAddr, equals('192.168.1.10'));
      expect(config.sshKeyPath, equals('./ssh/server-key'));
      expect(config.description, isNull);
      expect(config.username, isNull);
      expect(config.metadata, isNull);
    });

    test('fromYaml parses full config', () {
      final yaml = {
        'ip': '192.168.1.10',
        'ssh_key': '/absolute/path/to/key',
        'description': 'Primary web server',
        'username': 'admin',
        'metadata': {
          'location': 'rack-1',
          'environment': 'production',
        },
      };
      
      final config = SelfHostedServerConfig.fromYaml('web-server', yaml);
      
      expect(config.name, equals('web-server'));
      expect(config.ipAddr, equals('192.168.1.10'));
      expect(config.sshKeyPath, equals('/absolute/path/to/key'));
      expect(config.description, equals('Primary web server'));
      expect(config.username, equals('admin'));
      expect(config.metadata, isNotNull);
      expect(config.metadata!['location'], equals('rack-1'));
      expect(config.metadata!['environment'], equals('production'));
    });
  });

  group('SelfHosting', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nix-infra-test-');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('hasServersConfig returns false when no config exists', () async {
      expect(await SelfHosting.hasServersConfig(tempDir), isFalse);
    });

    test('hasServersConfig returns true when config exists', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('servers:\n  test: {ip: "1.1.1.1", ssh_key: "./ssh/key"}');
      
      expect(await SelfHosting.hasServersConfig(tempDir), isTrue);
    });

    test('load throws when servers.yaml is missing', () async {
      expect(
        () => SelfHosting.load(tempDir),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('servers.yaml not found'),
        )),
      );
    });

    test('load throws when servers key is missing', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('other_key: value');
      
      expect(
        () => SelfHosting.load(tempDir),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('must contain a "servers" key'),
        )),
      );
    });

    test('load throws when ip is missing', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  test-server:
    ssh_key: ./ssh/key
''');
      
      expect(
        () => SelfHosting.load(tempDir),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('missing required field "ip"'),
        )),
      );
    });

    test('load throws when ssh_key is missing', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  test-server:
    ip: 192.168.1.10
''');
      
      expect(
        () => SelfHosting.load(tempDir),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('missing required field "ssh_key"'),
        )),
      );
    });

    test('load parses valid config', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  web-server-1:
    ip: 192.168.1.10
    ssh_key: ./ssh/web-server-1
    description: Primary web server
    username: admin
    
  db-server-1:
    ip: 192.168.1.20
    ssh_key: /absolute/path/to/db-key
    description: Primary database server
''');
      
      final provider = await SelfHosting.load(tempDir);
      
      expect(provider.providerName, equals('Self-Hosting'));
      expect(provider.supportsCreateServer, isFalse);
      expect(provider.supportsDestroyServer, isFalse);
      expect(provider.supportsPlacementGroups, isFalse);
      
      expect(provider.servers.length, equals(2));
      expect(provider.servers['web-server-1'], isNotNull);
      expect(provider.servers['db-server-1'], isNotNull);
    });

    test('getServers returns all servers', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  server-1:
    ip: 192.168.1.10
    ssh_key: ./ssh/key1
  server-2:
    ip: 192.168.1.20
    ssh_key: ./ssh/key2
  server-3:
    ip: 192.168.1.30
    ssh_key: ./ssh/key3
''');
      
      final provider = await SelfHosting.load(tempDir);
      final servers = await provider.getServers();
      
      expect(servers.length, equals(3));
    });

    test('getServers filters by only parameter', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  server-1:
    ip: 192.168.1.10
    ssh_key: ./ssh/key1
  server-2:
    ip: 192.168.1.20
    ssh_key: ./ssh/key2
  server-3:
    ip: 192.168.1.30
    ssh_key: ./ssh/key3
''');
      
      final provider = await SelfHosting.load(tempDir);
      final servers = await provider.getServers(only: ['server-1', 'server-3']);
      
      expect(servers.length, equals(2));
      expect(servers.map((s) => s.name).toSet(), equals({'server-1', 'server-3'}));
    });

    test('getServers sets username from config', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  server-with-user:
    ip: 192.168.1.10
    ssh_key: ./ssh/key
    username: admin
  server-default-user:
    ip: 192.168.1.20
    ssh_key: ./ssh/key2
''');
      
      final provider = await SelfHosting.load(tempDir);
      final servers = (await provider.getServers()).toList();
      
      final serverWithUser = servers.firstWhere((s) => s.name == 'server-with-user');
      final serverDefaultUser = servers.firstWhere((s) => s.name == 'server-default-user');
      
      expect(serverWithUser.username, equals('admin'));
      expect(serverDefaultUser.username, equals('root'));
    });

    test('getServers sets sshKeyPath from config', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  server-relative:
    ip: 192.168.1.10
    ssh_key: ./ssh/my-key
  server-absolute:
    ip: 192.168.1.20
    ssh_key: /absolute/path/key
''');
      
      final provider = await SelfHosting.load(tempDir);
      final servers = (await provider.getServers()).toList();
      
      final serverRelative = servers.firstWhere((s) => s.name == 'server-relative');
      final serverAbsolute = servers.firstWhere((s) => s.name == 'server-absolute');
      
      expect(serverRelative.sshKeyPath, equals('./ssh/my-key'));
      expect(serverAbsolute.sshKeyPath, equals('/absolute/path/key'));
      
      // Test effective path resolution
      expect(
        serverRelative.getEffectiveSshKeyPath(tempDir.path),
        equals('${tempDir.path}/ssh/my-key'),
      );
      expect(
        serverAbsolute.getEffectiveSshKeyPath(tempDir.path),
        equals('/absolute/path/key'),
      );
    });

    test('getIpAddr returns correct IP', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  my-server:
    ip: 10.0.0.5
    ssh_key: ./ssh/key
''');
      
      final provider = await SelfHosting.load(tempDir);
      
      expect(await provider.getIpAddr('my-server'), equals('10.0.0.5'));
      expect(await provider.getIpAddr('non-existent'), isNull);
    });

    test('createServer throws UnsupportedError', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  server:
    ip: 192.168.1.10
    ssh_key: ./ssh/key
''');
      
      final provider = await SelfHosting.load(tempDir);
      
      expect(
        () => provider.createServer('new-server', 'type', 'loc', 'key', null),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('destroyServer throws UnsupportedError', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  server:
    ip: 192.168.1.10
    ssh_key: ./ssh/key
''');
      
      final provider = await SelfHosting.load(tempDir);
      
      expect(
        () => provider.destroyServer(123),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('getServerConfig returns config by name', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  my-server:
    ip: 192.168.1.10
    ssh_key: ./ssh/key
    description: Test server
''');
      
      final provider = await SelfHosting.load(tempDir);
      
      final config = provider.getServerConfig('my-server');
      expect(config, isNotNull);
      expect(config!.name, equals('my-server'));
      expect(config.description, equals('Test server'));
      
      expect(provider.getServerConfig('non-existent'), isNull);
    });
  });

  group('ProviderType', () {
    test('enum values', () {
      expect(ProviderType.values, contains(ProviderType.hcloud));
      expect(ProviderType.values, contains(ProviderType.selfHosting));
    });
  });

  group('InfrastructureProvider interface', () {
    test('HetznerCloud implements InfrastructureProvider', () {
      final provider = HetznerCloud(token: 'test-token', sshKey: 'test-key');
      
      expect(provider, isA<InfrastructureProvider>());
      expect(provider.providerName, equals('Hetzner Cloud'));
      expect(provider.supportsCreateServer, isTrue);
      expect(provider.supportsDestroyServer, isTrue);
      expect(provider.supportsPlacementGroups, isTrue);
    });
  });

  group('ProviderOperations extension', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('nix-infra-test-');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('tryCreateServer returns false for SelfHosting', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  server:
    ip: 192.168.1.10
    ssh_key: ./ssh/key
''');
      
      final provider = await SelfHosting.load(tempDir);
      
      final result = await provider.tryCreateServer(
        'new-server', 'type', 'loc', 'key', null,
      );
      
      expect(result, isFalse);
    });

    test('tryDestroyServer returns false for SelfHosting', () async {
      final configFile = File('${tempDir.path}/servers.yaml');
      await configFile.writeAsString('''
servers:
  server:
    ip: 192.168.1.10
    ssh_key: ./ssh/key
''');
      
      final provider = await SelfHosting.load(tempDir);
      
      final result = await provider.tryDestroyServer(123);
      
      expect(result, isFalse);
    });
  });
}
