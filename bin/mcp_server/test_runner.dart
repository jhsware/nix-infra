import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:process_run/shell.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';

/// Represents an active test session with cached output chunks
class TestSession {
  final String id;
  final String operation;
  final String testName;
  final DateTime startedAt;
  final List<String> chunks = [];
  bool isComplete = false;
  int? exitCode;
  StreamSubscription<String>? _subscription;

  TestSession({
    required this.id,
    required this.operation,
    required this.testName,
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

/// Manages active test sessions
class SessionManager {
  static final SessionManager _instance = SessionManager._internal();
  factory SessionManager() => _instance;
  SessionManager._internal();

  final Map<String, TestSession> _sessions = {};
  int _sessionCounter = 0;

  /// Creates a new session and returns its ID
  String createSession(String operation, String testName) {
    _sessionCounter++;
    final id =
        'session_${_sessionCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final session = TestSession(
      id: id,
      operation: operation,
      testName: testName,
    );
    _sessions[id] = session;
    return id;
  }

  /// Gets a session by ID
  TestSession? getSession(String id) => _sessions[id];

  /// Removes a session
  Future<void> removeSession(String id) async {
    final session = _sessions[id];
    if (session != null) {
      await session.cancel();
      _sessions.remove(id);
    }
  }

  /// Lists all active sessions
  List<TestSession> get activeSessions =>
      _sessions.values.where((s) => !s.isComplete).toList();

  /// Lists all sessions
  List<TestSession> get allSessions => _sessions.values.toList();

  /// Cleans up completed sessions older than the specified duration
  void cleanupOldSessions({Duration maxAge = const Duration(hours: 1)}) {
    final now = DateTime.now();
    _sessions.removeWhere((id, session) {
      return session.isComplete && now.difference(session.startedAt) > maxAge;
    });
  }
}

class TestRunner extends McpTool {
  static const description = 'Run tests on an existing test cluster.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'operation': {
      'type': 'string',
      'description': '''
run -- start a test run (returns session_id for polling output)
reset -- reset test cluster (returns session_id for polling output)
get_output -- get output chunks from a running or completed session
list_sessions -- list all active sessions
cancel -- cancel a running session
''',
      'enum': [
        'run',
        'reset',
        'get_output',
        'list_sessions',
        'cancel',
      ],
    },
    'test-name': {
      'type': 'string',
      'description': 'name of test (required for run and reset operations)'
    },
    'session_id': {
      'type': 'string',
      'description':
          'session ID returned from run/reset (required for get_output and cancel)'
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

  final SessionManager _sessionManager = SessionManager();

  TestRunner({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final operation = args!['operation'];
    final testName = args!['test-name'];
    final sessionId = args!['session_id'];
    final chunkIndex = args!['chunk_index'] ?? 0;
    final maxChunks = (args!['max_chunks'] ?? 50).clamp(1, 200);

    switch (operation) {
      case 'run':
        return _startOperation('run', testName);
      case 'reset':
        return _startOperation('reset', testName);
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

  /// Starts a run or reset operation and returns session info
  CallToolResult _startOperation(String operation, String? testName) {
    if (testName == null || testName.isEmpty) {
      return CallToolResult.fromContent(
        content: [TextContent(text: 'Missing test-name parameter')],
      );
    }

    if (testName.contains('/')) {
      return CallToolResult.fromContent(
        content: [TextContent(text: 'No "/" allowed')],
      );
    }

    final directory = Directory(getAbsolutePath('__test__/$testName'));
    if (!directory.existsSync()) {
      return CallToolResult.fromContent(
        content: [
          TextContent(
              text: 'Test not found: $testName (${directory.absolute.path})')
        ],
      );
    }

    // Create session and start collecting output
    final sessionId = _sessionManager.createSession(operation, testName);
    final session = _sessionManager.getSession(sessionId)!;

    // Start the appropriate command
    Stream<String> outputStream;
    if (operation == 'run') {
      outputStream =
          streamCommand(workingDir, '__test__/run-tests.sh run $testName');
    } else {
      outputStream =
          streamCommand(workingDir, '__test__/run-tests.sh reset $testName');
    }

    // Start collecting output in the background
    session.collectOutput(outputStream);

    // Return session info immediately
    final response = {
      'status': 'started',
      'session_id': sessionId,
      'operation': operation,
      'test_name': testName,
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
      'test_name': session.testName,
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
      response['message'] = 'All output has been retrieved. Operation complete.';
    }

    return CallToolResult.fromContent(
      content: [TextContent(text: jsonEncode(response))],
    );
  }

  /// Lists all sessions
  CallToolResult _listSessions() {
    // Clean up old sessions first
    _sessionManager.cleanupOldSessions();

    final sessions = _sessionManager.allSessions.map((s) => {
          'session_id': s.id,
          'operation': s.operation,
          'test_name': s.testName,
          'is_complete': s.isComplete,
          'chunks_collected': s.chunks.length,
          'started_at': s.startedAt.toIso8601String(),
        }).toList();

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

  // Keep the old methods for reference but they're no longer used directly
  Stream<String> runTest({required String name}) async* {
    if (name.toString().contains('/')) {
      yield 'No "/" allowed';
      return;
    }

    final directory = Directory(getAbsolutePath('__test__/$name'));
    if (!await directory.exists()) {
      yield 'Test not found: $name (${directory.absolute.path})';
      return;
    }

    yield* streamCommand(workingDir, '__test__/run-tests.sh run $name');
  }

  Stream<String> resetTestCluster({required String name}) async* {
    if (name.toString().contains('/')) {
      yield 'No "/" allowed';
      return;
    }

    final directory = Directory(getAbsolutePath('__test__/$name'));
    if (!await directory.exists()) {
      yield 'Test not found: $name (${directory.absolute.path})';
      return;
    }

    yield* streamCommand(workingDir, '__test__/run-tests.sh reset $name');
  }
}

/// Streams command output as it becomes available.
/// Each chunk is yielded as soon as it is received from the process.
/// Uses Process.start directly for true streaming behavior.
Stream<String> streamCommand(Directory workingDir, String cmd) {
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

/// Runs a command and collects all output before returning.
/// Kept for reference - use streamCommand for streaming output.
Future<List<String>> runCommand(Directory workingDir, String cmd) async {
  final List<String> outp = [];
  final controller = StreamController<List<int>>();
  controller.stream.listen((inp) {
    final str = utf8.decode(inp);
    outp.add(str);
  }, onError: (inp) {
    final str = utf8.decode(inp);
    outp.add('ERROR: $str');
  }, onDone: () {
    // Do nothing...
  });

  final shell = Shell(
    workingDirectory: workingDir.path,
    runInShell: true,
    stdout: controller.sink,
    verbose: true,
  );

  try {
    await shell.run(cmd);
  } on ShellException catch (err) {
    outp.add(err.message);
  }

  return outp;
}

String getAbsolutePath(String path) {
  final projectRootPath = Directory.current.absolute.path;
  final outp = path == '.' ? projectRootPath : '$projectRootPath/$path';
  return normalize(outp);
}
