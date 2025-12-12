import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';
import '../../bin/mcp_server/filesystem.dart';

void main() {
  test('list-content can be called', () async {
    final fs = FileSystem(
      workingDir: Directory.current,
      sshKeyName: 'fake',
      hcloudToken: 'fake',
    );
    final CallToolResult result = await fs.callback(
      args: {'operation': 'list-content'},
    );
    final tmp = result.content.first;
    expect(tmp.type, 'text');
    expect((tmp as TextContent).text, isNot('Directory not found: .'));
  });
}
