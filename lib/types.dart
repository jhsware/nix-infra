import 'package:path/path.dart' as path;

class ClusterConfiguration {
  String sshKeyName;
  String nixVersion;
  String domain;
  String location;
  String etcdClusterUuid;
  List<ClusterNode> ctrlNodes;
  String papertrailLogTarget;

  ClusterConfiguration(
      this.sshKeyName,
      this.nixVersion,
      this.domain,
      this.location,
      this.etcdClusterUuid,
      this.ctrlNodes,
      this.papertrailLogTarget);
}

/// Where the key of a machine comes from (docs/design/ssh_agent_keys.md §3,
/// §4.2). The provider sets it on each [ClusterNode] it lists, from the key
/// map (`keySourceFor` in lib/ssh_key_map.dart, the only place that knows the
/// order of §4.2). Without a key map every machine has a [KeyFileSource].
///
/// No field holds a private key. [AgentKeySource.agentSocket] is a path and
/// is never put into a text (design §7).
sealed class NodeKeySource {
  const NodeKeySource();
}

/// The classic way: a private key file, `ssh_key` of the machine in
/// servers.yaml or else `ssh/<SSH_KEY>` ([ClusterNode.getEffectiveSshKeyPath]
/// decides).
final class KeyFileSource extends NodeKeySource {
  const KeyFileSource();

  @override
  bool operator ==(Object other) => other is KeyFileSource;

  @override
  int get hashCode => (KeyFileSource).hashCode;

  @override
  String toString() => 'KeyFileSource()';
}

/// The key of the ssh-agent whose SHA-256 fingerprint is [fingerprint] (the
/// form that `ssh-add -l` prints) signs for the machine. Only that key is
/// used; no other key of the agent is offered to the machine.
final class AgentKeySource extends NodeKeySource {
  const AgentKeySource(this.fingerprint, {this.agentSocket});

  final String fingerprint;

  /// The socket of the agent: `SSH_AUTH_SOCK` of the configuration when the
  /// machine was listed, or null when it is not set (then the machine cannot
  /// be reached: "SSH_KEY_MAP_PATH is set but SSH_AUTH_SOCK is not.").
  final String? agentSocket;

  @override
  bool operator ==(Object other) =>
      other is AgentKeySource &&
      other.fingerprint == fingerprint &&
      other.agentSocket == agentSocket;

  @override
  int get hashCode => Object.hash(fingerprint, agentSocket);

  /// Without the socket: a text may show this object.
  @override
  String toString() => 'AgentKeySource($fingerprint)';
}

/// The key map says that the key of the machine is not available
/// (`{"unavailable": <reason>, "ring": <ring>}`). The machine is not reached
/// with another key.
final class UnavailableKeySource extends NodeKeySource {
  const UnavailableKeySource(this.reason);

  /// A ready text: the reason of the entry, and its ring when there is one
  /// (`secrets_locked, ring interactive`).
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is UnavailableKeySource && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'UnavailableKeySource($reason)';
}

/// A key map is set, but it could not be read when the machines were listed
/// (it was deleted or written again with an error while an MCP server runs).
/// Every machine of that listing gets this source; none is reached with
/// another key.
final class KeyMapUnreadableSource extends NodeKeySource {
  const KeyMapUnreadableSource(this.detail);

  /// What is wrong with the key map, one sentence without its path.
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is KeyMapUnreadableSource && other.detail == detail;

  @override
  int get hashCode => detail.hashCode;

  @override
  String toString() => 'KeyMapUnreadableSource($detail)';
}

class ClusterNode {
  int id;
  String name;
  String ipAddr;
  String username = 'root';
  String sshKeyName;

  /// Optional absolute path to the SSH key file.
  /// If set, this takes precedence over constructing path from sshKeyName.
  /// This is useful for self-hosted servers where keys may be stored
  /// in non-standard locations.
  String? sshKeyPath;

  /// True when [sshKeyPath] was set from `SSH_KEY_PATH` (one private key
  /// file for every machine of a CLI command) and not from servers.yaml or
  /// the key name. Only used for the text of an authentication error.
  bool sshKeyPathFromEnv;

  /// Where the key of this machine comes from. The default,
  /// [KeyFileSource], is the classic way ([getEffectiveSshKeyPath]); the
  /// provider sets another source from the key map (`SSH_KEY_MAP_PATH`).
  NodeKeySource keySource;

  /// Optional name of the VPN connection required to reach this server.
  /// Loaded from the `vpn` field in servers.yaml. When set and SSH is not
  /// reachable, the consuming agent should ask the user to start this VPN.
  String? vpn;

  /// Optional name of the cloud provider that hosts this server
  /// (e.g. 'hetzner'). Loaded from the `provider` field in servers.yaml,
  /// or set by the cloud provider that listed the server. Used to select
  /// the PROVIDER environment variable for nixos-infect per node.
  String? cloudProvider;

  ClusterNode(this.name, this.ipAddr, this.id, this.sshKeyName,
      {this.sshKeyPath,
      this.sshKeyPathFromEnv = false,
      this.keySource = const KeyFileSource(),
      this.vpn,
      this.cloudProvider});

  /// Whether a VPN connection is required to reach this server.
  bool get requiresVpn => vpn != null;

  /// Get the effective SSH key path, resolving relative to workingDir if needed.
  String getEffectiveSshKeyPath(String workingDirPath) {
    if (sshKeyPath != null) {
      if (sshKeyPath!.startsWith('/')) {
        // If sshKeyPath is absolute, use it directly
        return path.normalize(sshKeyPath!);
      }
      // Otherwise resolve relative to working directory
      return path.normalize('$workingDirPath/$sshKeyPath');
    }
    // Fall back to standard location
    return path.normalize('$workingDirPath/ssh/$sshKeyName');
  }
}

enum CertType {
  tls,
  peer,
}

class PlacementGroup {
  // https://docs.hetzner.cloud/#placement-groups-create-a-placementgroup
  DateTime created;
  int id;
  // "labels": {
  //   "key": "value"
  // },
  String name;
  // "servers": [],
  String type;

  PlacementGroup(this.created, this.id, this.name, this.type);
}
