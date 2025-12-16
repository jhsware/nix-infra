import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:process_run/shell.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_tool.dart';

class TestRunner extends McpTool {
  static const description = 'Run tests on an existing test cluster.';

  static const Map<String, dynamic> inputSchemaProperties = {
    'operation': {
      'type': 'string',
      'description': '''
run -- run test
reset -- reset test cluster (requires test-name)
''',
      'enum': [
        'run',
        'reset',
      ],
    },
    'test-name': {
      'type': 'string',
      'description': 'name of test (required for both run and reset)'
    },
  };

  TestRunner({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final operation = args!['operation'];
    final testName = args!['test-name'];

    Stream<String> resultStream;

    switch (operation) {
      case 'run':
        if (testName == null || testName.isEmpty) {
          return CallToolResult.fromContent(
            content: [TextContent(text: 'Missing test-name parameter')],
          );
        }
        resultStream = runTest(name: testName);
        break;
      case 'reset':
        if (testName == null || testName.isEmpty) {
          return CallToolResult.fromContent(
            content: [TextContent(text: 'Missing test-name parameter')],
          );
        }
        resultStream = resetTestCluster(name: testName);
        break;
      default:
        return CallToolResult.fromContent(
          content: [
            TextContent(
              text: 'No operation specified',
            ),
          ],
        );
    }

    // Collect streamed chunks and return as a single result
    // Each chunk is added as a separate TextContent for MCP streaming support
    final List<Content> contentChunks = [];
    await for (final chunk in resultStream) {
      contentChunks.add(TextContent(text: chunk));
    }

    if (contentChunks.isEmpty) {
      contentChunks.add(TextContent(text: ''));
    }

    return CallToolResult.fromContent(content: contentChunks);
  }

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
