import 'dart:io';
import 'package:test/test.dart';
import '../../bin/mcp_server/remote_command/bash_command_parser.dart';

List<String> testCommands = [
  'ls -la',
  'grep "hello world" file.txt',
  "echo 'single quoted string'",
  'find /home -name "*.dart" | grep test',
  'cd /tmp && ls -la',
  'echo "escaped \\"quotes\\"" file.txt',
  'ps aux; echo "done"',
  'git commit -m "Initial commit" && git push',
];

void main() {
  test('commands can be parsed', () {
    final List<List<ParsedCommand>> res = [];
    for (final cmd in testCommands) {
      List<ParsedCommand> parsed = BashCommandParser.parseCommands(cmd);
      res.add(parsed);
      print(parsed.toString());
    }
    expect(res[0][0].binary, 'ls');
  });
}
