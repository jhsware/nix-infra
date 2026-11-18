import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:nix_infra/ssh_key_map.dart';

// The key settings of the three MCP servers (docs/design/ssh_agent_keys.md
// §6.3): `SSH_KEY`, `SSH_KEY_MAP_PATH` and `SSH_AUTH_SOCK` of the
// configuration (`.env` overlaid with the process environment). No text of
// this file holds the path of the key map or of the socket: the stderr of an
// MCP server gets the rule of the tool results (design §7).

/// What an MCP server needs to give each machine its key.
class McpKeySettings {
  const McpKeySettings(
      {required this.sshKeyName, this.keyMapPath, this.agentSocket});

  /// `SSH_KEY`, or `''` when a key map is set and `SSH_KEY` is not.
  final String sshKeyName;

  /// The absolute path of the key map, or null without one.
  final String? keyMapPath;

  /// The socket of the ssh-agent, or null when `SSH_AUTH_SOCK` is not set.
  final String? agentSocket;
}

/// An MCP server cannot start; [message] is its line on stderr, without a
/// path.
class McpStartException implements Exception {
  const McpStartException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The key settings of an MCP server in [workingDir] with the configuration
/// [env].
///
/// - `SSH_KEY` is required without a key map, as before; with a key map it
///   is not (the key map gives the keys of the machines it names).
/// - A key map is read once here: one that cannot be read, or has another
///   version, stops the start. The path of the key map is not in the text.
///
/// Throws an [McpStartException].
McpKeySettings mcpKeySettings(DotEnv env, Directory workingDir) {
  final keyMapPath = resolveSshKeyMapPath(env, workingDir);
  final sshKeyName = env['SSH_KEY'];
  if (sshKeyName == null && keyMapPath == null) {
    throw const McpStartException('env-var SSH_KEY is missing');
  }
  if (keyMapPath != null) {
    try {
      loadSshKeyMap(keyMapPath);
    } on SshKeyMapException catch (e) {
      // e.message holds no path; e.path is not used.
      throw McpStartException('$kSshKeyMapPathEnv: ${e.message}');
    }
  }
  return McpKeySettings(
    sshKeyName: sshKeyName ?? '',
    keyMapPath: keyMapPath,
    agentSocket: resolveSshAgentSocket(env),
  );
}

/// [mcpKeySettings], or `ERROR! <text>` on stderr and exit code 2.
McpKeySettings mcpKeySettingsOrExit(DotEnv env, Directory workingDir) {
  try {
    return mcpKeySettings(env, workingDir);
  } on McpStartException catch (e) {
    stderr.writeln('ERROR! ${e.message}');
    exit(2);
  }
}
