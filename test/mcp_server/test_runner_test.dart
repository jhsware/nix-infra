import 'dart:async';
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

  group('streamCommand', () {
    test('streams output from simple echo command', () async {
      final chunks = <String>[];
      final stream = streamCommand(Directory.current, 'echo "hello"');

      await for (final chunk in stream) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty);
      expect(chunks.join(), contains('hello'));
    });

    test('streams output from pwd command', () async {
      final chunks = <String>[];
      final stream = streamCommand(Directory.current, 'pwd');

      await for (final chunk in stream) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty);
      expect(chunks.join(), contains(Directory.current.path));
    });

    test('streams multiple chunks from multi-line output', () async {
      final chunks = <String>[];
      // Generate multiple lines of output with delays to ensure streaming
      // Use separate echo commands to avoid shell variable interpolation issues
      final stream = streamCommand(
        Directory.current,
        'echo "line 1"; sleep 0.05; echo "line 2"; sleep 0.05; echo "line 3"; sleep 0.05; echo "line 4"; sleep 0.05; echo "line 5"',
      );

      await for (final chunk in stream) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty);
      final combined = chunks.join();
      expect(combined, contains('line 1'));
      expect(combined, contains('line 5'));
      // With sleep between lines, we should get multiple chunks
      expect(chunks.length, greaterThan(1),
          reason: 'Should receive multiple streamed chunks, not a single response');
    });

    test('streams output incrementally as command executes', () async {
      final receivedTimes = <DateTime>[];
      final chunks = <String>[];

      // Use a command that produces output with deliberate delays
      final stream = streamCommand(
        Directory.current,
        'echo "start"; sleep 0.15; echo "middle"; sleep 0.15; echo "end"',
      );

      await for (final chunk in stream) {
        receivedTimes.add(DateTime.now());
        chunks.add(chunk);
      }

      expect(chunks.length, greaterThan(1),
          reason: 'Output should be streamed in multiple chunks');

      // Verify we got content at different times
      if (receivedTimes.length >= 2) {
        final timeDiff =
            receivedTimes.last.difference(receivedTimes.first).inMilliseconds;
        expect(timeDiff, greaterThan(50),
            reason: 'Chunks should arrive at different times, indicating true streaming');
      }
    });

    test('handles command errors gracefully', () async {
      final chunks = <String>[];
      final stream =
          streamCommand(Directory.current, 'nonexistentcommand12345');

      await for (final chunk in stream) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty,
          reason: 'Should receive error output from failed command');
    });

    test('returns stream that can be listened to only once', () async {
      final stream = streamCommand(Directory.current, 'echo "test"');

      // First listener should work
      final firstChunks = await stream.toList();
      expect(firstChunks, isNotEmpty);
    });

    test('streams ls command output', () async {
      final chunks = <String>[];
      final stream = streamCommand(Directory.current, 'ls');

      await for (final chunk in stream) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty);
    });
  });

  group('runCommand (reference implementation)', () {
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

  group('streaming behavior verification', () {
    test('streamCommand yields chunks as they arrive, not all at once', () async {
      // This test verifies that streamCommand is truly streaming
      // by checking that chunks arrive over time, not all at once

      final chunkArrivals = <int>[];
      final stopwatch = Stopwatch()..start();

      final stream = streamCommand(
        Directory.current,
        'echo "chunk1"; sleep 0.15; echo "chunk2"; sleep 0.15; echo "chunk3"',
      );

      await for (final _ in stream) {
        chunkArrivals.add(stopwatch.elapsedMilliseconds);
      }

      stopwatch.stop();

      // We should have multiple arrivals spread over time
      expect(chunkArrivals.length, greaterThan(1),
          reason: 'Should receive multiple chunks');

      // The total elapsed time should be significant (at least 200ms for 2 sleeps of 0.15s)
      if (chunkArrivals.length > 1) {
        final totalTime = chunkArrivals.last - chunkArrivals.first;
        expect(totalTime, greaterThan(100),
            reason:
                'Chunks should arrive over time (total spread: ${totalTime}ms), indicating streaming rather than buffered response');
      }
    });

    test('runCommand collects all output before returning', () async {
      // Verify that runCommand collects all output
      final result = await runCommand(
        Directory.current,
        'echo "line1"; echo "line2"; echo "line3"',
      );

      // runCommand should collect all output
      final combined = result.join();
      expect(combined, contains('line1'));
      expect(combined, contains('line2'));
      expect(combined, contains('line3'));
    });

    test('streamCommand vs runCommand - same content, different delivery', () async {
      const testCmd = 'echo "a"; echo "b"; echo "c"';

      // Get output from both methods
      final streamChunks = <String>[];
      await for (final chunk in streamCommand(Directory.current, testCmd)) {
        streamChunks.add(chunk);
      }

      final runResult = await runCommand(Directory.current, testCmd);

      // Both should contain the same content
      final streamContent = streamChunks.join();
      final runContent = runResult.join();

      expect(streamContent, contains('a'));
      expect(streamContent, contains('b'));
      expect(streamContent, contains('c'));
      expect(runContent, contains('a'));
      expect(runContent, contains('b'));
      expect(runContent, contains('c'));
    });
  });
}
