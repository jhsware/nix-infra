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

  ClusterNode(this.name, this.ipAddr, this.id, this.sshKeyName);
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
