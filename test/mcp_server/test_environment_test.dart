import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/types.dart';
import '../../bin/mcp_server/test_environment.dart';

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
  group('TestEnvironment', () {
    late TestEnvironment testEnvironment;

    setUp(() {
      testEnvironment = TestEnvironment(
        workingDir: Directory.current,
        sshKeyName: 'fake',
        provider: MockProvider(),
      );
    });

    group('create operation', () {
      test('create returns error when test infra directory does not exist',
          () async {
        // This test will pass if the directory doesn't exist,
        // or start a session if it does
        final CallToolResult result = await testEnvironment.callback(
          args: {
            'operation': 'create',
          },
        );
        final text = (result.content.first as TextContent).text;
        // Either it's an error about missing directory/script, or it started
        expect(
          text.contains('not found') || text.contains('session_id'),
          isTrue,
        );
      });
    });

    group('destroy operation', () {
      test('destroy can be called', () async {
        final CallToolResult result = await testEnvironment.callback(
          args: {
            'operation': 'destroy',
          },
        );
        final text = (result.content.first as TextContent).text;
        // Either it's an error about missing directory/script, or it started
        expect(
          text.contains('not found') || text.contains('session_id'),
          isTrue,
        );
      });
    });

    group('status operation', () {
      test('status can be called', () async {
        final CallToolResult result = await testEnvironment.callback(
          args: {
            'operation': 'status',
          },
        );
        final text = (result.content.first as TextContent).text;
        // Either it's an error about missing directory/script, or it started
        expect(
          text.contains('not found') || text.contains('session_id'),
          isTrue,
        );
      });
    });

    group('get_output operation', () {
      test('get_output returns error when session_id is missing', () async {
        final CallToolResult result = await testEnvironment.callback(
          args: {
            'operation': 'get_output',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'Missing session_id parameter');
      });

      test('get_output returns error for non-existent session', () async {
        final CallToolResult result = await testEnvironment.callback(
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
        final CallToolResult result = await testEnvironment.callback(
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
        final CallToolResult result = await testEnvironment.callback(
          args: {
            'operation': 'cancel',
          },
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'Missing session_id parameter');
      });

      test('cancel returns error for non-existent session', () async {
        final CallToolResult result = await testEnvironment.callback(
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
        final CallToolResult result = await testEnvironment.callback(
          args: {},
        );
        final text = (result.content.first as TextContent).text;
        expect(text, 'No operation specified');
      });
    });
  });

  group('TestEnvironmentSessionManager', () {
    late TestEnvironmentSessionManager sessionManager;

    setUp(() {
      sessionManager = TestEnvironmentSessionManager();
    });

    test('createSession returns unique session ID', () {
      final id1 = sessionManager.createSession('create');
      final id2 = sessionManager.createSession('destroy');
      final id3 = sessionManager.createSession('status');

      expect(id1, isNotEmpty);
      expect(id2, isNotEmpty);
      expect(id3, isNotEmpty);
      expect(id1, isNot(equals(id2)));
      expect(id2, isNot(equals(id3)));
      expect(id1, startsWith('env_session_'));
      expect(id2, startsWith('env_session_'));
      expect(id3, startsWith('env_session_'));
    });

    test('getSession returns created session for status operation', () {
      final id = sessionManager.createSession('status');
      final session = sessionManager.getSession(id);

      expect(session, isNotNull);
      expect(session!.id, id);
      expect(session.operation, 'status');
    });

    test('getSession returns created session for create operation', () {
      final id = sessionManager.createSession('create');
      final session = sessionManager.getSession(id);

      expect(session, isNotNull);
      expect(session!.id, id);
      expect(session.operation, 'create');
    });

    test('getSession returns created session for destroy operation', () {
      final id = sessionManager.createSession('destroy');
      final session = sessionManager.getSession(id);

      expect(session, isNotNull);
      expect(session!.id, id);
      expect(session.operation, 'destroy');
    });

    test('getSession returns null for unknown session', () {
      final session = sessionManager.getSession('unknown_id');
      expect(session, isNull);
    });

    test('removeSession removes the session', () async {
      final id = sessionManager.createSession('create');
      expect(sessionManager.getSession(id), isNotNull);

      await sessionManager.removeSession(id);
      expect(sessionManager.getSession(id), isNull);
    });

    test('allSessions returns all sessions', () {
      sessionManager.createSession('create');
      sessionManager.createSession('destroy');

      final sessions = sessionManager.allSessions;
      expect(sessions.length, greaterThanOrEqualTo(2));
    });

    test('activeSessions returns only incomplete sessions', () {
      final id1 = sessionManager.createSession('create');
      final id2 = sessionManager.createSession('destroy');

      // Mark one as complete
      sessionManager.getSession(id1)!.isComplete = true;

      final active = sessionManager.activeSessions;
      expect(active.any((s) => s.id == id1), isFalse);
      expect(active.any((s) => s.id == id2), isTrue);
    });
  });

  group('TestEnvironmentSession', () {
    test('collects output from stream', () async {
      final session = TestEnvironmentSession(
        id: 'test_session',
        operation: 'create',
      );

      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      controller.add('Creating environment...\n');
      controller.add('Setting up cluster...\n');
      controller.add('Done!\n');
      await controller.close();

      // Wait a bit for async processing
      await Future.delayed(Duration(milliseconds: 50));

      expect(session.chunks.length, 3);
      expect(session.chunks[0], 'Creating environment...\n');
      expect(session.chunks[1], 'Setting up cluster...\n');
      expect(session.chunks[2], 'Done!\n');
      expect(session.isComplete, isTrue);
    });

    test('handles stream errors gracefully', () async {
      final session = TestEnvironmentSession(
        id: 'test_session',
        operation: 'destroy',
      );

      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      controller.add('Starting destroy...\n');
      controller.addError('Connection failed');

      // Wait a bit for async processing
      await Future.delayed(Duration(milliseconds: 50));

      expect(session.chunks, contains('Starting destroy...\n'));
      expect(session.chunks.join(), contains('ERROR'));
      expect(session.isComplete, isTrue);
    });

    test('cancel stops collecting output', () async {
      final session = TestEnvironmentSession(
        id: 'test_session',
        operation: 'create',
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
      final sessionManager = TestEnvironmentSessionManager();
      final sessionId = sessionManager.createSession('create');
      final session = sessionManager.getSession(sessionId)!;

      // Simulate output arriving in chunks
      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      // Add chunks with slight delays to simulate real output
      for (var i = 0; i < 10; i++) {
        controller.add('Setup step $i\n');
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
      expect(page1[0], 'Setup step 0\n');

      // Second page (chunks 5-9)
      startIndex = 5;
      endIndex = (startIndex + maxChunks).clamp(0, session.chunks.length);
      var page2 = session.chunks.sublist(startIndex, endIndex);
      expect(page2.length, 5);
      expect(page2[0], 'Setup step 5\n');

      // Third page (no more chunks)
      startIndex = 10;
      endIndex = (startIndex + maxChunks).clamp(0, session.chunks.length);
      var page3 = startIndex < session.chunks.length
          ? session.chunks.sublist(startIndex, endIndex)
          : <String>[];
      expect(page3.length, 0);
    });

    test('client can poll while operation is running', () async {
      final sessionManager = TestEnvironmentSessionManager();
      final sessionId = sessionManager.createSession('destroy');
      final session = sessionManager.getSession(sessionId)!;

      final controller = StreamController<String>();
      session.collectOutput(controller.stream);

      // Add first chunk
      controller.add('Initializing destroy...\n');
      await Future.delayed(Duration(milliseconds: 10));

      // Poll while running - should see partial output
      expect(session.chunks.length, 1);
      expect(session.isComplete, isFalse);

      // Add more chunks
      controller.add('Removing servers...\n');
      controller.add('Cleaning up resources...\n');
      await Future.delayed(Duration(milliseconds: 10));

      // Poll again - should see more output
      expect(session.chunks.length, 3);
      expect(session.isComplete, isFalse);

      // Complete the operation
      controller.add('Environment destroyed!\n');
      await controller.close();
      await Future.delayed(Duration(milliseconds: 10));

      // Final poll - should see all output and completion
      expect(session.chunks.length, 4);
      expect(session.isComplete, isTrue);
    });
  });

  group('TestEnvironment constants', () {
    test('has correct test infra path', () {
      // Verify testInfraPath is a valid absolute path
      expect(TestEnvironment.testInfraPath, isNotEmpty);
      expect(path.isAbsolute(TestEnvironment.testInfraPath), isTrue);
    });

    test('has description', () {
      expect(TestEnvironment.description, isNotEmpty);
      expect(TestEnvironment.description, contains('test environment'));
    });

    test('has input schema with all operations', () {
      final schema = TestEnvironment.inputSchemaProperties;
      expect(schema['operation'], isNotNull);
      final operations = schema['operation']['enum'] as List;
      expect(operations, contains('create'));
      expect(operations, contains('destroy'));
      expect(operations, contains('status'));
      expect(operations, contains('get_output'));
      expect(operations, contains('list_sessions'));
      expect(operations, contains('cancel'));
    });

    test('input schema does not contain test operation', () {
      final schema = TestEnvironment.inputSchemaProperties;
      final operations = schema['operation']['enum'] as List;
      expect(operations, isNot(contains('test')));
    });
  });
}
