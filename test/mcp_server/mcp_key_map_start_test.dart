// The start of the machine MCP server with a key map (docs/design/
// ssh_agent_keys.md §6.3, §7), through its real entry point. Compiles the
// server once per test. No test connects to a machine.
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _timeout = Timeout(Duration(minutes: 2));

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_mcp_key_map_');
    // One machine on an address of TEST-NET-1 (RFC 5737), never reached.
    File('${dir.path}/servers.yaml').writeAsStringSync(
        'servers:\n  web-1:\n    ip: 192.0.2.10\n    ssh_key: ./ssh/web-1\n');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Only what `dart run` needs from the process environment, so a SSH_KEY,
  /// SSH_KEY_MAP_PATH or SSH_AUTH_SOCK of the developer's shell does not
  /// leak in.
  Map<String, String> cleanEnvironment(Map<String, String> extra) {
    const passThrough = ['PATH', 'HOME', 'PUB_CACHE', 'TMPDIR'];
    return {
      for (final name in passThrough)
        if (Platform.environment[name] != null)
          name: Platform.environment[name]!,
      ...extra,
    };
  }

  List<String> serverArgs() => [
        'run',
        '--verbosity=error',
        'bin/nix_infra_machine_mcp.dart',
        '--project-dir=${dir.path}',
      ];

  /// Runs the server until it exits (for a start that fails).
  Future<ProcessResult> runServer(Map<String, String> environment) =>
      Process.run(Platform.resolvedExecutable, serverArgs(),
          workingDirectory: Directory.current.path,
          environment: cleanEnvironment(environment),
          includeParentEnvironment: false);

  void writeMap(String content) =>
      File('${dir.path}/keys/map.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  test('with a key map and no SSH_KEY the server starts and answers',
      () async {
    writeMap(jsonEncode({
      'version': 1,
      'default': {'agent_key': 'SHA256:u2l0c8QfR1vN0mJ5rT8hD4kX9aYb3Wq7eZs6PpLo1Hg'},
    }));
    final process = await Process.start(
        Platform.resolvedExecutable, serverArgs(),
        workingDirectory: Directory.current.path,
        environment: cleanEnvironment({
          'SSH_KEY_MAP_PATH': '${dir.path}/keys/map.json',
          'SSH_AUTH_SOCK': '${dir.path}/agent.sock',
        }),
        includeParentEnvironment: false);
    final stderrText = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderrText.write);
    final answer = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.contains('"id":1'), orElse: () => '');
    var exitCode = -1;
    unawaited(process.exitCode.then((code) => exitCode = code));
    try {
      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'clientInfo': {'name': 'nix-infra-test', 'version': '0.0.0'},
        },
      }));
      await process.stdin.flush();
      final line = await answer.timeout(const Duration(seconds: 90));

      expect(exitCode, -1, reason: 'the server must not exit: $stderrText');
      expect(line, contains('"result"'), reason: '$stderrText');
      expect(line, contains('nix-infra-machine-mcp'));
      expect(stderrText.toString(), isNot(contains('SSH_KEY is missing')));
    } finally {
      process.kill();
      await process.exitCode;
    }
  }, timeout: _timeout);

  test('a key map of another version in .env: exit code 2, no path',
      () async {
    writeMap('{"version": 2}');
    File('${dir.path}/.env')
        .writeAsStringSync('SSH_KEY=k\nSSH_KEY_MAP_PATH=keys/map.json\n');
    final r = await runServer({});
    final stderrText = '${r.stderr}';

    expect(r.exitCode, 2, reason: '${r.stdout}$stderrText');
    expect(
        stderrText.trim(),
        'ERROR! SSH_KEY_MAP_PATH: The key map has version 2; nix-infra reads '
        'version 1.');
    expect(stderrText, isNot(contains(dir.path)));
    expect(stderrText, isNot(contains('keys/map.json')));
  }, timeout: _timeout);

  test('a missing key map: exit code 2, no path', () async {
    final r = await runServer(
        {'SSH_KEY_MAP_PATH': '${dir.path}/keys/missing.json'});
    final stderrText = '${r.stderr}';

    expect(r.exitCode, 2, reason: '${r.stdout}$stderrText');
    expect(stderrText.trim(),
        'ERROR! SSH_KEY_MAP_PATH: The key map cannot be read.');
    expect(stderrText, isNot(contains(dir.path)));
  }, timeout: _timeout);

  test('without SSH_KEY and a key map: exit code 2 as before', () async {
    final r = await runServer({'SSH_AUTH_SOCK': '${dir.path}/agent.sock'});
    expect(r.exitCode, 2, reason: '${r.stdout}${r.stderr}');
    expect('${r.stderr}'.trim(), 'ERROR! env-var SSH_KEY is missing');
  }, timeout: _timeout);
}
