import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/types.dart';
import '../../bin/mcp_server/test_runner.dart';

/// Mock provider for testing purposes
class MockProvider implements InfrastructureProvider {
  @override
  String get providerName => 'Mock';

  @override
  bool get supportsCreateServer => false;

  @override
  bool get supportsDestroyServer => false;

  @override
  bool get supportsPlacementGroups => false;

  @override
  Future<Iterable<ClusterNode>> getServers({List<String>? only}) async => [];

  @override
  Future<void> createServer(
    String name,
    String machineType,
    String location,
    String sshKeyName,
    int? placementGroupId,
  ) async {
    throw UnsupportedError('Mock provider does not support creating servers');
  }

  @override
  Future<void> destroyServer(int id) async {
    throw UnsupportedError('Mock provider does not support destroying servers');
  }

  @override
  Future<String?> getIpAddr(String name) async => null;

  @override
  Future<void> addSshKeyToCloudProvider(
      Directory workingDir, String keyName) async {}

  @override
  Future<void> removeSshKeyFromCloudProvider(
      Directory workingDir, String keyName) async {}
}

void main() {
  group('TestRunner', () {
    late TestRunner testRunner;

    setUp(() {
      testRunner = TestRunner(
        workingDir: Directory.current,
        sshKeyName: 'fake',
        provider: MockProvider(),
      );
    });

    group('run operation', () {
      test('run can be called', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'run',
            'test-name': 'fake-test',
          },
        );
        final tmp = result.content.first;
        expect(tmp.type, 'text');
      });

      test('run returns error for test with slash in name', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'run',
            'test-name': 'invalid/test',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'No "/" allowed');
      });

      test('run returns error for non-existent test', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'run',
            'test-name': 'non-existent-test-xyz',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, contains('Test not found'));
      });
    });

    group('reset operation', () {
      test('reset can be called', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'reset',
          },
        );
        final tmp = result.content.first;
        expect(tmp.type, 'text');
      });
    });

    group('default operation', () {
      test('returns message when no operation specified', () async {
        final CallToolResult result = await testRunner.callback(
          args: {},
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'No operation specified');
      });
    });
  });

  group('runCommand', () {
    test('can be called with simple command', () async {
      final res = await runCommand(Directory.current, 'ls');
      expect(res, isNotNull);
      expect(res, isA<List<String>>());
    });

    test('can run echo command', () async {
      final res = await runCommand(Directory.current, 'echo "hello"');
      expect(res, isNotNull);
      expect(res.join(), contains('hello'));
    });

    test('returns output from command', () async {
      final res = await runCommand(Directory.current, 'pwd');
      expect(res, isNotNull);
      expect(res.join(), contains(Directory.current.path));
    });

    test('handles command that does not exist', () async {
      final res =
          await runCommand(Directory.current, 'nonexistentcommand12345');
      expect(res, isNotNull);
      // Should contain error message
      expect(res.isNotEmpty, isTrue);
    });
  });

  group('getAbsolutePath', () {
    test('returns current directory for "."', () {
      final result = getAbsolutePath('.');
      expect(result, Directory.current.absolute.path);
    });

    test('appends relative path to current directory', () {
      final result = getAbsolutePath('fake-dir');
      expect(result, '${Directory.current.absolute.path}/fake-dir');
    });

    test('handles path starting with "./"', () {
      final result = getAbsolutePath('./fake-dir');
      expect(result, '${Directory.current.absolute.path}/fake-dir');
    });

    test('normalizes path with ".."', () {
      final result = getAbsolutePath('some/path/../other');
      expect(result, '${Directory.current.absolute.path}/some/other');
    });

    test('normalizes path with multiple ".."', () {
      final result = getAbsolutePath('a/b/c/../../d');
      expect(result, '${Directory.current.absolute.path}/a/d');
    });

    test('normalizes path with "."', () {
      final result = getAbsolutePath('some/./path');
      expect(result, '${Directory.current.absolute.path}/some/path');
    });
  });
}
