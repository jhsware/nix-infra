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

  ClusterNode(this.name, this.ipAddr, this.id, this.sshKeyName,
      {this.sshKeyPath});

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
