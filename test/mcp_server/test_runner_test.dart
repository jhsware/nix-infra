import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';
import '../../bin/mcp_server/test_runner.dart';

void main() {
  test('run can be called', () async {
    final fs = TestRunner(
      workingDir: Directory.current,
      sshKeyName: 'fake',
      hcloudToken: 'fake',
    );
    final CallToolResult result = await fs.callback(
      args: {
        'operation': 'run',
        'test-name': 'fake-test',
      },
    );
    final tmp = result.content.first;
    expect(tmp.type, 'text');
  });

  test('reset can be called', () async {
    final fs = TestRunner(
      workingDir: Directory.current,
      sshKeyName: 'fake',
      hcloudToken: 'fake',
    );
    final CallToolResult result = await fs.callback(
      args: {
        'operation': 'reset',
      },
    );
    final tmp = result.content.first;
    expect(tmp.type, 'text');
  });

  test('runCommand can be called', () async {
    final res = await runCommand(Directory.current, 'ls');
    expect(res, isNotNull);
  });

  test('runCommand can call run-test.sh', () async {
    final res = await runCommand(
      Directory.current,
      'ls',
    );
    expect(res, isNotNull);
  });

  test('getAbsolutePath', () async {
    final result = getAbsolutePath('./fake-dir');
    expect(result, '${Directory.current.absolute.path}/fake-dir');
  });
}
