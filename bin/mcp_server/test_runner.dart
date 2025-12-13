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
reset -- reset test cluster
''',
      'enum': [
        'run',
        'reset',
      ],
    },
    'test-name': {'type': 'string', 'description': 'name of test'},
  };

  TestRunner({
    required super.workingDir,
    required super.sshKeyName,
    required super.provider,
  });

  Future<CallToolResult> callback({args, extra}) async {
    final operation = args!['operation'];
    final testName = args!['test-name'] ?? '.';

    String result = 'No operation specified';

    switch (operation) {
      case 'run':
        result = await runTest(name: testName);
        break;
      case 'reset':
        result = await resetTestCluster();
        break;
    }

    return CallToolResult.fromContent(
      content: [
        TextContent(
          text: result,
        ),
      ],
    );
  }

  Future<String> runTest({required String name}) async {
    if (name.toString().contains('/')) {
      return 'No "/" allowed';
    }

    final directory = Directory(getAbsolutePath('__test__/$name'));
    if (!await directory.exists()) {
      return 'Test not found: $name (${directory.absolute.path})';
    }

    final Iterable<String> res =
        await runCommand(workingDir, '__test__/run-tests.sh run $name');

    return res.join('\n');
  }

  Future<String> resetTestCluster() async {
    final Iterable<String> res =
        await runCommand(workingDir, '__test__/run-tests.sh reset');

    return res.join('\n');
  }
}

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
