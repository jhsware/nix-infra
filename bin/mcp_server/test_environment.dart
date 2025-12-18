import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:process_run/shell.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';

/// Represents an active test environment session with cached output chunks
class TestEnvironmentSession {
  final String id;
  final String operation;
  final DateTime startedAt;
  final List<String> chunks = [];
  bool isComplete = false;
  int? exitCode;
  StreamSubscription<String>? _subscription;

  TestEnvironmentSession({
    required this.id,
    required this.operation,
  }) : startedAt = DateTime.now();

  /// Starts collecting output from the stream
  void collectOutput(Stream<String> stream) {
    _subscription = stream.listen(
      (chunk) {
        chunks.add(chunk);
      },
      onDone: () {
        isComplete = true;
      },
      onError: (error) {
        chunks.add('ERROR: $error\n');
        isComplete = true;
      },
    );
  }

  /// Cancel the subscription if still active
  Future<void> cancel() async {
    await _subscription?.cancel();
    isComplete = true;
  }
}

/// Manages active test environment sessions
class TestEnvironmentSessionManager {
  static final TestEnvironmentSessionManager _instance =
      TestEnvironmentSessionManager._internal();
  factory TestEnvironmentSessionManager() => _instance;
  TestEnvironmentSessionManager._internal();

  final Map<String, TestEnvironmentSession> _sessions = {};
  int _sessionCounter = 0;

  /// Creates a new session and returns its ID
  String createSession(String operation) {
    _sessionCounter++;
    final id =
        'env_session_${_sessionCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final session = TestEnvironmentSession(
      id: id,
      operation: operation,
    );
    _sessions[id] = session;
    return id;
  }

  /// Gets a session by ID
  TestEnvironmentSession? getSession(String id) => _sessions[id];

  /// Removes a session
  Future<void> removeSession(String id) async {
    final session = _sessions[id];
    if (session != null) {
      await session.cancel();
      _sessions.remove(id);
    }
  }

  /// Lists all active sessions
  List<TestEnvironmentSession> get activeSessions =>
      _sessions.values.where((s) => !s.isComplete).toList();

  /// Lists all sessions
  List<TestEnvironmentSession> get allSessions => _sessions.values.toList();

  /// Cleans up completed sessions older than the specified duration
  void cleanupOldSessions({Duration maxAge = const Duration(hours: 1)}) {
    final now = DateTime.now();
    _sessions.removeWhere((id, session) {
      return session.isComplete && now.difference(session.startedAt) > maxAge;
    });
  }
}

class TestEnvironment extends McpTool {
  static const description =
      'Manage test environment for HA cluster testing. Create and destroy test clusters.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'operation': {
      'type': 'string',
      'description': '''
create -- create a new test environment/cluster (returns session_id for polling output)
destroy -- destroy the test environment/cluster (returns session_id for polling output)
status -- check the health status of the test cluster (returns session_id for polling output)
get_output -- get output chunks from a running or completed session
list_sessions -- list all active sessions
cancel -- cancel a running session
''',
      'enum': [
        'create',
        'destroy',
        'status',
        'get_output',
        'list_sessions',
        'cancel',
      ],
    },
    'session_id': {
      'type': 'string',
      'description':
          'session ID returned from create/test (required for get_output and cancel)'
    },
    'chunk_index': {
      'type': 'integer',
      'description':
          'starting chunk index for get_output (default: 0). Use this to paginate through output.'
    },
    'max_chunks': {
      'type': 'integer',
      'description':
          'maximum number of chunks to return in get_output (default: 50, max: 200)'
    },
  };

  /// Path to the test infrastructure directory (current working directory)
  static String get testInfraPath => getAbsolutePath('.');

  final TestEnvironmentSessionManager _sessionManager =
      TestEnvironmentSessionManager();

  TestEnvironment({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final operation = args!['operation'];
    final sessionId = args!['session_id'];
    final chunkIndex = args!['chunk_index'] ?? 0;
    final maxChunks = (args!['max_chunks'] ?? 50).clamp(1, 200);

    switch (operation) {
      case 'create':
        return _startOperation('create');
      case 'destroy':
        return _startOperation('destroy');
      case 'status':
        return _startOperation('status');
      case 'get_output':
        return _getOutput(sessionId, chunkIndex, maxChunks);
      case 'list_sessions':
        return _listSessions();
      case 'cancel':
        return _cancelSession(sessionId);
      default:
        return CallToolResult.fromContent(
          content: [
            TextContent(
              text: 'No operation specified',
            ),
          ],
        );
    }
  }

  /// Starts a create or destroy operation and returns session info
  CallToolResult _startOperation(String operation) {
    final testInfraDir = Directory(testInfraPath);
    if (!testInfraDir.existsSync()) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
              text:
                  'Test infrastructure directory not found: $testInfraPath')
        ],
      );
    }

    final runTestsScript = File('$testInfraPath/__test__/run-tests.sh');
    if (!runTestsScript.existsSync()) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
              text:
                  'run-tests.sh script not found: ${runTestsScript.path}')
        ],
      );
    }

    // Create session and start collecting output
    final sessionId = _sessionManager.createSession(operation);
    final session = _sessionManager.getSession(sessionId)!;

    // Build the command
    final cmd = '__test__/run-tests.sh $operation';

    // Start the command
    final outputStream = _streamCommand(Directory(testInfraPath), cmd);

    // Start collecting output in the background
    session.collectOutput(outputStream);

    // Return session info immediately
    final response = {
      'status': 'started',
      'session_id': sessionId,
      'operation': operation,
      'working_directory': testInfraPath,
      'message':
          'Operation started. Use get_output with session_id to retrieve output chunks.',
    };

    return CallToolResult.fromContent(
      content: [TextContent(text: jsonEncode(response))],
    );
  }

  /// Gets output chunks from a session
  CallToolResult _getOutput(String? sessionId, int chunkIndex, int maxChunks) {
    if (sessionId == null || sessionId.isEmpty) {
      return CallToolResult.fromContent(
        content: [TextContent(text: 'Missing session_id parameter')],
      );
    }

    final session = _sessionManager.getSession(sessionId);
    if (session == null) {
      final response = {
        'error': 'Session not found',
        'session_id': sessionId,
      };
      return CallToolResult.fromContent(
        content: [TextContent(text: jsonEncode(response))],
      );
    }

    // Get the requested chunk range
    final totalChunks = session.chunks.length;
    final startIndex = chunkIndex.clamp(0, totalChunks);
    final endIndex = (startIndex + maxChunks).clamp(0, totalChunks);

    final chunks = startIndex < totalChunks
        ? session.chunks.sublist(startIndex, endIndex)
        : <String>[];

    final hasMoreChunks = endIndex < totalChunks;
    final nextChunkIndex = hasMoreChunks ? endIndex : null;

    final response = {
      'session_id': sessionId,
      'operation': session.operation,
      'is_complete': session.isComplete,
      'total_chunks': totalChunks,
      'chunk_index': startIndex,
      'chunks_returned': chunks.length,
      'has_more_chunks': hasMoreChunks || !session.isComplete,
      'next_chunk_index': nextChunkIndex,
      'output': chunks.join(''),
    };

    // Add guidance for the client
    if (!session.isComplete && !hasMoreChunks) {
      response['message'] =
          'Operation still running. Poll again with the same chunk_index to get new output.';
    } else if (hasMoreChunks) {
      response['message'] =
          'More chunks available. Call get_output with chunk_index: $nextChunkIndex';
    } else if (session.isComplete && !hasMoreChunks) {
      response['message'] =
          'All output has been retrieved. Operation complete.';
    }

    return CallToolResult.fromContent(
      content: [TextContent(text: jsonEncode(response))],
    );
  }

  /// Lists all sessions
  CallToolResult _listSessions() {
    // Clean up old sessions first
    _sessionManager.cleanupOldSessions();

    final sessions = _sessionManager.allSessions
        .map((s) => {
              'session_id': s.id,
              'operation': s.operation,
              'is_complete': s.isComplete,
              'chunks_collected': s.chunks.length,
              'started_at': s.startedAt.toIso8601String(),
            })
        .toList();

    final response = {
      'sessions': sessions,
      'total': sessions.length,
    };

    return CallToolResult.fromContent(
      content: [TextContent(text: jsonEncode(response))],
    );
  }

  /// Cancels a running session
  Future<CallToolResult> _cancelSession(String? sessionId) async {
    if (sessionId == null || sessionId.isEmpty) {
      return CallToolResult.fromContent(
        content: [TextContent(text: 'Missing session_id parameter')],
      );
    }

    final session = _sessionManager.getSession(sessionId);
    if (session == null) {
      final response = {
        'error': 'Session not found',
        'session_id': sessionId,
      };
      return CallToolResult.fromContent(
        content: [TextContent(text: jsonEncode(response))],
      );
    }

    await _sessionManager.removeSession(sessionId);

    final response = {
      'status': 'cancelled',
      'session_id': sessionId,
      'message': 'Session has been cancelled and removed.',
    };

    return CallToolResult.fromContent(
      content: [TextContent(text: jsonEncode(response))],
    );
  }

  /// Streams command output as it becomes available.
  Stream<String> _streamCommand(Directory workingDir, String cmd) {
    final controller = StreamController<String>();

    // Start the process asynchronously
    Process.start(
      '/bin/sh',
      ['-c', cmd],
      workingDirectory: workingDir.path,
      runInShell: false,
    ).then((process) {
      // Track when both streams are done
      var stdoutDone = false;
      var stderrDone = false;

      void checkClose() {
        if (stdoutDone && stderrDone) {
          process.exitCode.then((exitCode) {
            if (exitCode != 0) {
              controller.add('Process exited with code: $exitCode\n');
            }
            controller.close();
          });
        }
      }

      // Stream stdout
      process.stdout.transform(utf8.decoder).listen(
        (data) {
          controller.add(data);
        },
        onError: (error) {
          controller.add('STDOUT ERROR: $error\n');
        },
        onDone: () {
          stdoutDone = true;
          checkClose();
        },
      );

      // Stream stderr
      process.stderr.transform(utf8.decoder).listen(
        (data) {
          controller.add(data);
        },
        onError: (error) {
          controller.add('STDERR ERROR: $error\n');
        },
        onDone: () {
          stderrDone = true;
          checkClose();
        },
      );
    }).catchError((error) {
      controller.add('Failed to start process: $error\n');
      controller.close();
    });

    return controller.stream;
  }
}

String getAbsolutePath(String path) {
  final projectRootPath = Directory.current.absolute.path;
  final outp = path == '.' ? projectRootPath : '$projectRootPath/$path';
  return normalize(outp);
}
