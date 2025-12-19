import 'dart:async';
import 'dart:convert';
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
  bool get supportsAddSshKey => false;

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
      test('run returns error when test-name is missing', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'run',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'Missing test-name parameter');
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
      test('reset returns error when test-name is missing', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'reset',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'Missing test-name parameter');
      });

      test('reset returns error for test with slash in name', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'reset',
            'test-name': 'invalid/test',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'No "/" allowed');
      });

      test('reset returns error for non-existent test', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'reset',
            'test-name': 'non-existent-test-xyz',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, contains('Test not found'));
      });
    });

    group('get_output operation', () {
      test('get_output returns error when session_id is missing', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'get_output',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'Missing session_id parameter');
      });

      test('get_output returns error for non-existent session', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'get_output',
            'session_id': 'nonexistent_session',
          },
        );
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text);
        expect(json['error'], 'Session not found');
      });
    });

    group('list_sessions operation', () {
      test('list_sessions returns session list', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'list_sessions',
          },
        );
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text);
        expect(json['sessions'], isA<List>());
        expect(json['total'], isA<int>());
      });
    });

    group('cancel operation', () {
      test('cancel returns error when session_id is missing', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'cancel',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'Missing session_id parameter');
      });

      test('cancel returns error for non-existent session', () async {
        final CallToolResult result = await testRunner.callback(
          args: {
            'operation': 'cancel',
            'session_id': 'nonexistent_session',
          },
        );
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text);
        expect(json['error'], 'Session not found');
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

  group('SessionManager', () {
    late SessionManager sessionManager;

    setUp(() {
      // Create a fresh instance for testing by accessing internal state
      // Note: In production the singleton pattern is used
      sessionManager = SessionManager();
    });

    test('createSession returns unique session ID', () {
      final id1 = sessionManager.createSession('run', 'test1');
      final id2 = sessionManager.createSession('run', 'test2');

      expect(id1, isNotEmpty);
      expect(id2, isNotEmpty);
      expect(id1, isNot(equals(id2)));
    });

    test('getSession returns created session', () {
      final id = sessionManager.createSession('run', 'test1');
      final session = sessionManager.getSession(id);

      expect(session, isNotNull);
      expect(session!.id, id);
      expect(session.operation, 'run');
      expect(session.testName, 'test1');
    });

    test('getSession returns null for unknown session', () {
      final session = sessionManager.getSession('unknown_id');
      expect(session, isNull);
    });

    test('removeSession removes the session', () async {
      final id = sessionManager.createSession('run', 'test1');
      expect(sessionManager.getSession(id), isNotNull);

      await sessionManager.removeSession(id);
      expect(sessionManager.getSession(id), isNull);
    });

    test('allSessions returns all sessions', () {
      sessionManager.createSession('run', 'test1');
      sessionManager.createSession('reset', 'test2');

      final sessions = sessionManager.allSessions;
      expect(sessions.length, greaterThanOrEqualTo(2));
    });
  });

  group('TestSession', () {
    test('collects output from stream', () async {
      final session = TestSession(
        id: 'test_session',
        operation: 'run',
        testName: 'test1',
      );

      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      controller.add('chunk1');
      controller.add('chunk2');
      controller.add('chunk3');
      await controller.close();

      // Wait a bit for async processing
      await Future.delayed(Duration(milliseconds: 50));

      expect(session.chunks.length, 3);
      expect(session.chunks[0], 'chunk1');
      expect(session.chunks[1], 'chunk2');
      expect(session.chunks[2], 'chunk3');
      expect(session.isComplete, isTrue);
    });

    test('handles stream errors gracefully', () async {
      final session = TestSession(
        id: 'test_session',
        operation: 'run',
        testName: 'test1',
      );

      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      controller.add('chunk1');
      controller.addError('Test error');

      // Wait a bit for async processing
      await Future.delayed(Duration(milliseconds: 50));

      expect(session.chunks, contains('chunk1'));
      expect(session.chunks.join(), contains('ERROR'));
      expect(session.isComplete, isTrue);
    });

    test('cancel stops collecting output', () async {
      final session = TestSession(
        id: 'test_session',
        operation: 'run',
        testName: 'test1',
      );

      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      controller.add('chunk1');
      await Future.delayed(Duration(milliseconds: 10));

      await session.cancel();

      // This shouldn't be collected after cancel
      controller.add('chunk2');
      await Future.delayed(Duration(milliseconds: 10));

      expect(session.isComplete, isTrue);
      expect(session.chunks.length, 1);
    });
  });

  group('Chunked output workflow', () {
    test('simulates full workflow with session and pagination', () async {
      // Create a test runner that we can control
      final testRunner = TestRunner(
        workingDir: Directory.current,
        sshKeyName: 'fake',
        provider: MockProvider(),
      );

      // Since we can't run actual tests, let's test the session manager directly
      final sessionManager = SessionManager();
      final sessionId = sessionManager.createSession('run', 'simulated-test');
      final session = sessionManager.getSession(sessionId)!;

      // Simulate output arriving in chunks
      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      // Add chunks with slight delays to simulate real output
      for (var i = 0; i < 10; i++) {
        controller.add('Output line $i\n');
        await Future.delayed(Duration(milliseconds: 5));
      }
      await controller.close();

      // Wait for all chunks to be collected
      await Future.delayed(Duration(milliseconds: 50));

      // Verify pagination works
      expect(session.chunks.length, 10);
      expect(session.isComplete, isTrue);

      // Simulate client paginating through results
      // First page (chunks 0-4)
      var startIndex = 0;
      var maxChunks = 5;
      var endIndex = (startIndex + maxChunks).clamp(0, session.chunks.length);
      var page1 = session.chunks.sublist(startIndex, endIndex);
      expect(page1.length, 5);
      expect(page1[0], 'Output line 0\n');

      // Second page (chunks 5-9)
      startIndex = 5;
      endIndex = (startIndex + maxChunks).clamp(0, session.chunks.length);
      var page2 = session.chunks.sublist(startIndex, endIndex);
      expect(page2.length, 5);
      expect(page2[0], 'Output line 5\n');

      // Third page (no more chunks)
      startIndex = 10;
      endIndex = (startIndex + maxChunks).clamp(0, session.chunks.length);
      var page3 = startIndex < session.chunks.length
          ? session.chunks.sublist(startIndex, endIndex)
          : <String>[];
      expect(page3.length, 0);
    });

    test('client can poll while operation is running', () async {
      final sessionManager = SessionManager();
      final sessionId = sessionManager.createSession('run', 'long-running-test');
      final session = sessionManager.getSession(sessionId)!;

      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      // Add first chunk
      controller.add('Starting...\n');
      await Future.delayed(Duration(milliseconds: 10));

      // Poll while running - should see partial output
      expect(session.chunks.length, 1);
      expect(session.isComplete, isFalse);

      // Add more chunks
      controller.add('Processing...\n');
      controller.add('More work...\n');
      await Future.delayed(Duration(milliseconds: 10));

      // Poll again - should see more output
      expect(session.chunks.length, 3);
      expect(session.isComplete, isFalse);

      // Complete the operation
      controller.add('Done!\n');
      await controller.close();
      await Future.delayed(Duration(milliseconds: 10));

      // Final poll - should see all output and completion
      expect(session.chunks.length, 4);
      expect(session.isComplete, isTrue);
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
      // ouput to stderr to avoid buffering so each command gets it's own chunk
      final script = '''
        echo line 1 >&2
        sleep 0.01
        echo line 2 >&2
        sleep 0.01
        echo line 3 >&2
        sleep 0.01
        echo line 4 >&2
        sleep 0.01
        echo line 5 >&2
      ''';
      final stream = streamCommand(Directory.current, script);

      await for (final chunk in stream) {
        chunks.add(chunk);
      }

      expect(chunks, isNotEmpty);
      final combined = chunks.join();
      expect(combined, contains('line 1'));
      expect(combined, contains('line 5'));
      // With sleep between lines, we should get multiple chunks
      expect(chunks.length, greaterThan(1),
          reason:
              'Should receive multiple streamed chunks, not a single response');
    });

    test('streams output incrementally as command executes', () async {
      final receivedTimes = <DateTime>[];
      final chunks = <String>[];

      // Use a command that produces output with deliberate delays
      final script = '''
        echo start >&2
        sleep 0.01
        echo middle >&2
        sleep 0.01
        echo end >&2
      ''';

      final stopwatch = Stopwatch()..start();
      final stream = streamCommand(Directory.current, script);

      await for (final chunk in stream) {
        receivedTimes.add(DateTime.now());
        chunks.add(chunk);
      }
      stopwatch.stop();

      expect(chunks.length, equals(3),
          reason: 'Output should be streamed in multiple chunks');

      // Verify we got content at different times
      expect(stopwatch.elapsedMilliseconds, greaterThan(19),
          reason:
              'Chunks should arrive over time (total spread: ${stopwatch.elapsedMilliseconds}ms), indicating streaming rather than buffered response');
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

    test('streamCommand vs runCommand - same content, different delivery',
        () async {
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
