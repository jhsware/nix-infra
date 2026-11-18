import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:path/path.dart' as p;

import 'package:nix_infra/types.dart';

// The key map of the agent mode (docs/design/ssh_agent_keys.md §4.1, §4.2):
// a JSON file, named by SSH_KEY_MAP_PATH, that says which key of the
// ssh-agent signs for a machine, or that the key of a machine is not
// available.
//
//   {"version": 1,
//    "default": {"agent_key": "SHA256:..."},
//    "nodes": {"web-1": {"agent_key": "SHA256:..."},
//              "db-1": {"unavailable": "secrets_locked", "ring": "interactive"}}}
//
// The key map holds SHA-256 fingerprints of public keys (the form that
// `ssh-add -l` prints) and reasons. It never holds a key, neither a private
// nor a public one, and is no secret.
//
// No text of this file holds the path of the key map: an MCP tool result
// must not show it (design §7). The path is a field of [SshKeyMapException],
// so the CLI may print it.

/// The variable that names the key map.
const kSshKeyMapPathEnv = 'SSH_KEY_MAP_PATH';

/// The variable that names the socket of the ssh-agent. Used only for a
/// machine that the key map gives an agent key: `SSH_AUTH_SOCK` alone
/// changes nothing (design §3).
const kSshAuthSockEnv = 'SSH_AUTH_SOCK';

/// The version of the key map that nix-infra reads.
const sshKeyMapVersion = 1;

/// The path of the key map that [env] names ([kSshKeyMapPathEnv]), absolute
/// and normalized, or null when the variable is not set or is empty (after
/// trimming).
///
/// An absolute value is used as it is; any other value is relative to
/// [workingDir], the project folder. A leading `~/` is not expanded. Whether
/// the file exists is checked by [loadSshKeyMap].
String? resolveSshKeyMapPath(DotEnv env, Directory workingDir) {
  final value = env[kSshKeyMapPathEnv]?.trim();
  if (value == null || value.isEmpty) return null;
  return p.normalize(
      p.isAbsolute(value) ? value : p.join(workingDir.absolute.path, value));
}

/// The socket of the ssh-agent that [env] names ([kSshAuthSockEnv]), or
/// null when the variable is not set or is empty (after trimming). The
/// value is used as it is.
String? resolveSshAgentSocket(DotEnv env) {
  final value = env[kSshAuthSockEnv]?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// What the key map says about the key of a machine.
sealed class SshKeyMapEntry {
  const SshKeyMapEntry();
}

/// The key of the agent with the fingerprint [fingerprint] signs for the
/// machine (`{"agent_key": "SHA256:..."}`).
final class AgentKeyEntry extends SshKeyMapEntry {
  const AgentKeyEntry(this.fingerprint);

  /// The SHA-256 fingerprint of the public key, in the form that
  /// `ssh-add -l` prints. Compared exactly with the keys of the agent.
  final String fingerprint;

  @override
  bool operator ==(Object other) =>
      other is AgentKeyEntry && other.fingerprint == fingerprint;

  @override
  int get hashCode => fingerprint.hashCode;

  @override
  String toString() => 'AgentKeyEntry($fingerprint)';
}

/// The key of the machine is not available, for [reason]
/// (`{"unavailable": "secrets_locked", "ring": "interactive"}`). A machine
/// with this entry is not reached with another key.
final class UnavailableEntry extends SshKeyMapEntry {
  const UnavailableEntry(this.reason, {this.ring});

  /// Why the key is not available, as the writer of the key map says it.
  final String reason;

  /// The optional `ring` of the entry, as the writer of the key map says it.
  final String? ring;

  @override
  bool operator ==(Object other) =>
      other is UnavailableEntry && other.reason == reason && other.ring == ring;

  @override
  int get hashCode => Object.hash(reason, ring);

  @override
  String toString() => 'UnavailableEntry($reason, ring: $ring)';
}

/// A key map: an entry for each machine it names, and an optional default.
final class SshKeyMap {
  const SshKeyMap({this.defaultEntry, this.nodes = const {}});

  /// The entry `default`, for every machine that [nodes] does not name.
  final SshKeyMapEntry? defaultEntry;

  /// The entries of `nodes`, by machine name.
  final Map<String, SshKeyMapEntry> nodes;

  /// The entry of the machine [nodeName] (design §4.2): `nodes[nodeName]`,
  /// else `default`, else null; with null the caller uses the key files.
  ///
  /// The name is compared exactly, case and all. There are no patterns:
  /// `web-*` is the name of one machine.
  SshKeyMapEntry? entryFor(String nodeName) => nodes[nodeName] ?? defaultEntry;
}

/// A key map that cannot be read or does not follow the schema.
///
/// [message] and [toString] never hold the path of the key map (design §7);
/// the CLI may print [path] itself.
final class SshKeyMapException implements Exception {
  const SshKeyMapException(this.path, this.message);

  /// The path of the key map.
  final String path;

  /// What is wrong, as one sentence, without the path.
  final String message;

  @override
  String toString() => 'SshKeyMapException: $message';
}

/// Reads the key map at [path]. The file is read at each call; nothing is
/// cached, so the caller may replace the file between two calls.
///
/// Throws an [SshKeyMapException] when the file cannot be read, is not one
/// JSON object, has another `version` than [sshKeyMapVersion], or has an
/// entry that does not follow the schema. Unknown fields are ignored at
/// every level.
SshKeyMap loadSshKeyMap(String path) {
  Never fail(String message) => throw SshKeyMapException(path, message);

  final List<int> bytes;
  try {
    bytes = File(path).readAsBytesSync();
  } on FileSystemException {
    // Its text holds the path: not passed on.
    fail('The key map cannot be read.');
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    // Also for bytes that are not UTF-8.
    fail('The key map is not valid JSON.');
  }
  if (json is! Map<String, dynamic>) fail('The key map is not a JSON object.');

  if (!json.containsKey('version')) {
    fail('The key map has no "version"; nix-infra reads version '
        '$sshKeyMapVersion.');
  }
  final version = json['version'];
  if (version is! num || version != sshKeyMapVersion) {
    fail('The key map has version ${_shown(version)}; nix-infra reads '
        'version $sshKeyMapVersion.');
  }

  final defaultEntry = json.containsKey('default')
      ? _entry(json['default'], '"default"', fail)
      : null;

  final nodes = <String, SshKeyMapEntry>{};
  if (json.containsKey('nodes')) {
    final nodesValue = json['nodes'];
    if (nodesValue is! Map<String, dynamic>) {
      fail('The field "nodes" of the key map is not a JSON object.');
    }
    for (final MapEntry(:key, :value) in nodesValue.entries) {
      nodes[key] = _entry(value, 'machine ${jsonEncode(key)}', fail);
    }
  }
  return SshKeyMap(defaultEntry: defaultEntry, nodes: nodes);
}

/// The entry [value] of [owner] (`"default"` or `machine "<name>"`).
SshKeyMapEntry _entry(
    Object? value, String owner, Never Function(String message) fail) {
  if (value is! Map<String, dynamic>) {
    fail('The key map entry of $owner is not a JSON object.');
  }
  final hasAgentKey = value.containsKey('agent_key');
  if (hasAgentKey == value.containsKey('unavailable')) {
    fail('The key map entry of $owner must have either "agent_key" or '
        '"unavailable".');
  }
  if (hasAgentKey) {
    return AgentKeyEntry(_text(value, 'agent_key', owner, fail));
  }
  final reason = _text(value, 'unavailable', owner, fail);
  if (!value.containsKey('ring')) return UnavailableEntry(reason);
  final ring = value['ring'];
  if (ring is! String) {
    fail('"ring" of the key map entry of $owner is not a string.');
  }
  return UnavailableEntry(reason, ring: ring);
}

/// The field [name] of [entry], a non-empty string.
String _text(Map<String, dynamic> entry, String name, String owner,
    Never Function(String message) fail) {
  final value = entry[name];
  if (value is! String || value.trim().isEmpty) {
    fail('"$name" of the key map entry of $owner is not a non-empty string.');
  }
  return value;
}

/// [value] as JSON for a message, shortened.
String _shown(Object? value) {
  final text = jsonEncode(value);
  return text.length <= 40 ? text : '${text.substring(0, 37)}...';
}


/// The key source of the machine [nodeName] (design §4.2). This is the only
/// place that knows the order of the rules:
///
/// 1. `nodes[<name>]` of the key map;
/// 2. `default` of the key map;
/// 3. and 4. no entry, or no key map ([map] null): [KeyFileSource], so
///    [ClusterNode.getEffectiveSshKeyPath] chooses between `ssh_key` of
///    servers.yaml and `ssh/<SSH_KEY>`.
///
/// There is no fall-through after rule 1 or 2: an `unavailable` entry gives
/// an [UnavailableKeySource], never a key file. [agentSocket] (the value of
/// `SSH_AUTH_SOCK`) is put into an [AgentKeySource].
NodeKeySource keySourceFor(SshKeyMap? map, String nodeName,
    {String? agentSocket}) {
  if (map == null) return const KeyFileSource();
  return switch (map.entryFor(nodeName)) {
    null => const KeyFileSource(),
    AgentKeyEntry(:final fingerprint) =>
      AgentKeySource(fingerprint, agentSocket: agentSocket),
    UnavailableEntry(:final reason, :final ring) =>
      UnavailableKeySource(ring == null ? reason : '$reason, ring $ring'),
  };
}

/// The key sources of one listing of machines: reads the key map at
/// [keyMapPath] now, once, and returns the function that gives the key
/// source of a machine by name ([keySourceFor]).
///
/// Call it each time the machines are listed (`getServers`): nothing is
/// cached, so a key map that the caller wrote again while an MCP server
/// runs is seen (design §4.1, §13).
///
/// - [keyMapPath] null (no key map): every machine has a [KeyFileSource],
///   whatever [agentSocket] holds.
/// - A key map that cannot be read now: every machine gets a
///   [KeyMapUnreadableSource]; the listing itself does not fail, and no
///   machine is reached with another key.
NodeKeySource Function(String nodeName) keySourcesForListing(
    String? keyMapPath,
    {String? agentSocket}) {
  if (keyMapPath == null) return (_) => const KeyFileSource();
  final SshKeyMap map;
  try {
    map = loadSshKeyMap(keyMapPath);
  } on SshKeyMapException catch (e) {
    final unreadable = KeyMapUnreadableSource(e.message);
    return (_) => unreadable;
  }
  return (nodeName) => keySourceFor(map, nodeName, agentSocket: agentSocket);
}