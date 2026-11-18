// The texts of docs/design/ssh_agent_keys.md §7 in the results of the MCP
// tools that connect: one test for each row (the row "the machine refuses
// the key" needs a real sshd: test/ssh_agent_mode_login_test.dart). The
// machine is listed by SelfHosting with a key map, as in an MCP server; the
// agent is the fake agent of test/support. Nothing connects: the key is
// resolved before a connection is made.
//
// No text may name the temporary folders of the test, where the key file,
// the key map and the socket of the agent are.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:nix_infra/providers/providers.dart';
import 'package:nix_infra/ssh_agent.dart';
import 'package:test/test.dart';

import '../../bin/mcp_server/file_upload.dart';
import '../../bin/mcp_server/remote_command.dart';
import '../../bin/mcp_server/system_stats.dart';
import '../support/fake_ssh_agent.dart';

String textOf(CallToolResult result) =>
    (result.content.first as TextContent).text;

void main() {
  late Directory dir;
  late String mapPath;
  late FakeSshAgent agent;
  late Uint8List key;
  late String fingerprint;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('nix_infra_key_texts_');
    mapPath = '${dir.path}/keys/key_map.json';
    // web-1 on an address of TEST-NET-1 (RFC 5737), never reached.
    File('${dir.path}/servers.yaml').writeAsStringSync(
        'servers:\n  web-1:\n    ip: 192.0.2.10\n    ssh_key: ./ssh/web-1\n');
    File('${dir.path}/upload.txt').writeAsStringSync('hello');
    agent = await FakeSshAgent.start();
    key = fakeKeyBlob('ssh-ed25519');
    fingerprint = sshKeyFingerprint(key);
  });

  tearDown(() async {
    await agent.stop();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// The agent lists [keys] and refuses every other request.
  void agentHolds(List<Uint8List> keys) {
    agent.answer = (request) => FakeAnswer(frame(
        request.first == SshAgentMessage.requestIdentities
            ? [
                SshAgentMessage.identitiesAnswer,
                ...uint32(keys.length),
                for (final k in keys) ...[...sshString(k), ...sshString([])],
              ]
            : [SshAgentMessage.failure]));
  }

  void writeMap(Map<String, dynamic>? json) {
    if (json == null) return;
    File(mapPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(json));
  }

  /// A provider as an MCP server makes it: with the key map [map] (none
  /// when null) and the socket [socket].
  Future<InfrastructureProvider> provider(Map<String, dynamic>? map,
      {String? socket}) async {
    writeMap(map);
    return SelfHosting.load(dir,
        sshKeyMapPath: map == null ? null : mapPath, sshAgentSocket: socket);
  }

  Map<String, dynamic> defaultKey(String fp) => {
        'version': 1,
        'default': {'agent_key': fp},
      };

  /// The results of remote-command, system-stats and file-upload for web-1
  /// carry [text], and no path of the test.
  Future<void> expectTexts(InfrastructureProvider provider, String text) async {
    const timeout = Duration(seconds: 5);
    final remote = RemoteCommand(
        workingDir: dir,
        sshKeyName: '',
        provider: provider,
        sshConnectTimeout: timeout);
    final stats = SystemStats(
        workingDir: dir,
        sshKeyName: '',
        provider: provider,
        sshConnectTimeout: timeout);
    final upload = FileUpload(
        workingDir: dir,
        sshKeyName: '',
        provider: provider,
        sshConnectTimeout: timeout);

    // remote-command does not catch: mcp_dart turns the error into the
    // result.
    Object? thrown;
    try {
      await remote.callback(args: {'target': 'web-1', 'command': 'uptime'});
    } catch (e) {
      thrown = e;
    }
    final remoteText = '$thrown';
    final statsText = textOf(await stats
        .callback(args: {'target': 'web-1', 'operation': 'health'}));
    final uploadText = textOf(await upload.callback(
        args: {'target': 'web-1', 'local_path': '${dir.path}/upload.txt'}));

    expect(remoteText, 'Exception: $text');
    expect(statsText, '--- web-1 (192.0.2.10) ---\nError: Exception: $text');
    expect(uploadText, 'web-1: ERROR - $text');
    for (final result in [remoteText, statsText, uploadText]) {
      expect(result, isNot(contains(dir.path)));
      expect(result, isNot(contains(agent.dir.path)));
      expect(result, isNot(contains('/tmp/')));
    }
  }

  test('an unavailable entry', () async {
    await expectTexts(
        await provider({
          'version': 1,
          'default': {'agent_key': fingerprint},
          'nodes': {
            'web-1': {'unavailable': 'secrets_locked', 'ring': 'interactive'},
          },
        }, socket: agent.socketPath),
        'The SSH key of machine "web-1" is not available (secrets_locked, '
        'ring interactive).');
    expect(agent.connections, 0);
  });

  test('the agent cannot be reached (no socket file)', () async {
    await expectTexts(
        await provider(defaultKey(fingerprint),
            socket: '${agent.dir.path}/missing.sock'),
        'The SSH agent of this session cannot be reached. The key of machine '
        '"web-1" is not available.');
  });

  test('the agent cannot be reached (nobody listens any more)', () async {
    final socket = '${agent.dir.path}/closed.sock';
    final server = await ServerSocket.bind(
        InternetAddress(socket, type: InternetAddressType.unix), 0);
    await server.close();
    await expectTexts(
        await provider(defaultKey(fingerprint), socket: socket),
        'The SSH agent of this session cannot be reached. The key of machine '
        '"web-1" is not available.');
  });

  for (final (what, setUpAgent) in [
    ('holds other keys', (FakeSshAgent _) {}),
    ('is empty', (FakeSshAgent _) {}),
    ('answers SSH_AGENT_FAILURE', (FakeSshAgent a) {
      a.answer = (_) => FakeAnswer(frame([SshAgentMessage.failure]));
    }),
  ]) {
    test('the agent does not hold the key: it $what', () async {
      agentHolds(what == 'is empty' ? [] : [fakeKeyBlob('ssh-rsa')]);
      setUpAgent(agent);
      await expectTexts(
          await provider(defaultKey(fingerprint), socket: agent.socketPath),
          'The SSH agent does not hold the key of machine "web-1" '
          '($fingerprint). If sysops filled the agent: the vault may be '
          'locked.');
    });
  }

  test('a key map but no SSH_AUTH_SOCK', () async {
    await expectTexts(await provider(defaultKey(fingerprint)),
        'SSH_KEY_MAP_PATH is set but SSH_AUTH_SOCK is not.');
  });

  test('a key file that does not exist (no key map)', () async {
    await expectTexts(await provider(null),
        'The SSH key file of machine "web-1" does not exist.');
  });

  test('a key map that cannot be read while the server runs', () async {
    final listing = await provider(defaultKey(fingerprint),
        socket: agent.socketPath);
    // Written again by the caller, broken.
    File(mapPath).writeAsStringSync('{"version": 1, "default": ');
    await expectTexts(
        listing,
        'The key map of this session cannot be read. The key of machine '
        '"web-1" is not available.');
  });
}
