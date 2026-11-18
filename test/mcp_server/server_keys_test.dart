// The key settings of the MCP servers (bin/mcp_server/server_keys.dart) and
// the variables of the agent mode that the dev MCP server passes to the
// scripts it starts (docs/design/ssh_agent_keys.md §6.3, §7, §14).
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/ssh_key_map.dart';
import 'package:test/test.dart';

import '../../bin/mcp_server/server_keys.dart';
import '../../bin/mcp_server/test_environment.dart';
import '../../bin/mcp_server/test_runner.dart';

/// DotEnv() does not include the platform environment.
DotEnv envOf(Map<String, String> values) => DotEnv()..addAll(values);

/// The text of the first content of [result].
String textOf(CallToolResult result) =>
    (result.content.first as TextContent).text;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nix_infra_server_keys_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void writeMap(String relativePath, String content) =>
      File('${dir.path}/$relativePath')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  group('mcpKeySettings', () {
    test('SSH_KEY without a key map: as before', () {
      final keys = mcpKeySettings(
          envOf({'SSH_KEY': 'my-key', 'SSH_AUTH_SOCK': '/tmp/a.sock'}), dir);
      expect(keys.sshKeyName, 'my-key');
      expect(keys.keyMapPath, isNull);
      // The socket is passed on, but without a key map no machine uses it.
      expect(keys.agentSocket, '/tmp/a.sock');
    });

    test('no SSH_KEY and no key map: the text of before', () {
      expect(
          () => mcpKeySettings(envOf({}), dir),
          throwsA(isA<McpStartException>().having(
              (e) => e.message, 'message', 'env-var SSH_KEY is missing')));
    });

    test('a key map and no SSH_KEY: the key map path, absolute', () {
      writeMap('keys/map.json', '{"version": 1}');
      final keys = mcpKeySettings(
          envOf({
            'SSH_KEY_MAP_PATH': 'keys/map.json',
            'SSH_AUTH_SOCK': '/tmp/a.sock',
          }),
          dir);
      expect(keys.sshKeyName, '');
      expect(keys.keyMapPath, '${dir.path}/keys/map.json');
      expect(keys.agentSocket, '/tmp/a.sock');
    });

    for (final (what, content, text) in [
      (
        'another version',
        '{"version": 2}',
        'SSH_KEY_MAP_PATH: The key map has version 2; nix-infra reads '
            'version 1.'
      ),
      (
        'not JSON',
        'not json',
        'SSH_KEY_MAP_PATH: The key map is not valid JSON.'
      ),
      (
        'a missing file',
        null,
        'SSH_KEY_MAP_PATH: The key map cannot be read.'
      ),
    ]) {
      test('a key map with $what stops the start, without its path', () {
        if (content != null) writeMap('keys/map.json', content);
        expect(
            () => mcpKeySettings(
                envOf({'SSH_KEY': 'k', 'SSH_KEY_MAP_PATH': 'keys/map.json'}),
                dir),
            throwsA(isA<McpStartException>()
                .having((e) => e.message, 'message', text)
                .having((e) => e.toString(), 'toString()',
                    isNot(contains(dir.path)))));
      });
    }
  });

  group('sshAgentScriptEnvironment', () {
    test('without a key map: empty, whatever SSH_AUTH_SOCK holds', () {
      expect(sshAgentScriptEnvironment(envOf({'SSH_AUTH_SOCK': '/a.sock'}), dir),
          isEmpty);
    });

    test('a relative key map of .env becomes absolute; the socket is passed',
        () {
      expect(
          sshAgentScriptEnvironment(
              envOf({
                'SSH_KEY_MAP_PATH': 'keys/map.json',
                'SSH_AUTH_SOCK': '/tmp/agent.sock',
              }),
              dir),
          {
            'SSH_KEY_MAP_PATH': '${dir.path}/keys/map.json',
            'SSH_AUTH_SOCK': '/tmp/agent.sock',
          });
    });

    test('a key map without SSH_AUTH_SOCK passes only the key map', () {
      expect(
          sshAgentScriptEnvironment(
              envOf({'SSH_KEY_MAP_PATH': '/keys/map.json'}), dir),
          {'SSH_KEY_MAP_PATH': '/keys/map.json'});
    });
  });

  group('the dev MCP server passes the variables to its scripts', () {
    late Map<String, String> scriptEnvironment;
    late InfrastructureProvider provider;

    setUp(() async {
      File('${dir.path}/servers.yaml').writeAsStringSync(
          'servers:\n  web-1:\n    ip: 192.0.2.1\n    ssh_key: ./ssh/k\n');
      provider = await SelfHosting.load(dir);
      // As from .env: a relative key map and a socket.
      scriptEnvironment = sshAgentScriptEnvironment(
          envOf({
            'SSH_KEY_MAP_PATH': 'keys/map.json',
            'SSH_AUTH_SOCK': '/tmp/agent.sock',
          }),
          dir);
      final script = File('${dir.path}/__test__/run-tests.sh')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n'
            'echo "MAP=\$SSH_KEY_MAP_PATH SOCK=\$SSH_AUTH_SOCK ARGS=\$*"\n');
      await Process.run('chmod', ['+x', script.path]);
      Directory('${dir.path}/__test__/t1').createSync();
    });

    /// Polls get_output of [tool] for [sessionId] until it is complete and
    /// returns the output.
    Future<String> outputOf(
        Future<CallToolResult> Function({Map<String, dynamic>? args})
            callback,
        String sessionId) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (true) {
        final response = jsonDecode(textOf(await callback(
            args: {'operation': 'get_output', 'session_id': sessionId})));
        if (response['is_complete'] == true) return response['output'];
        if (DateTime.now().isAfter(deadline)) fail('no output: $response');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    String expected(String args) => 'MAP=${dir.path}/keys/map.json '
        'SOCK=/tmp/agent.sock ARGS=$args';

    test('test-runner', () async {
      final runner = TestRunner(
          workingDir: dir,
          sshKeyName: '',
          provider: provider,
          scriptEnvironment: scriptEnvironment);
      final started = jsonDecode(textOf(await runner
          .callback(args: {'operation': 'run', 'test-name': 't1'})));
      final output = await outputOf(
          ({args}) => runner.callback(args: args), started['session_id']);
      expect(output.trim(), expected('run t1'));
    });

    test('test-environment', () async {
      final environment = TestEnvironment(
          workingDir: dir,
          sshKeyName: '',
          provider: provider,
          scriptEnvironment: scriptEnvironment);
      final started = jsonDecode(
          textOf(await environment.callback(args: {'operation': 'status'})));
      final output = await outputOf(
          ({args}) => environment.callback(args: args), started['session_id']);
      expect(output.trim(), expected('status'));
    });

    test('streamCommand without the variables passes nothing new', () async {
      final output = await streamCommand(
              dir, 'echo "MAP=\${SSH_KEY_MAP_PATH:-none}"',
              environment: const {})
          .join();
      // Unless the developer's shell set it, the script does not see it.
      if (Platform.environment['SSH_KEY_MAP_PATH'] == null) {
        expect(output.trim(), 'MAP=none');
      }
    });
  });
}
