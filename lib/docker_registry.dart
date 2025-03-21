import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'package:cli_script/cli_script.dart';

String _getHashFromOCIManifest(dynamic manifest) {
  // tar -ztvf app-pod.tar.gz
  // tar -O -xf app-pod.tar.gz manifest.json
  // https://blog.quarkslab.com/digging-into-the-oci-image-specification.html
  String hash = manifest[0]['Config'].split('/')[2];
  return hash.substring(0, 12);
}

Future<void> publishImageToRegistry(
  Directory workingDir,
  Iterable<ClusterNode> cluster,
  ClusterNode registryNode, {
  required String file,
  required String name,
  required String tag,
  bool debug = false,
}) async {
  final overlayMeshIps = await getOverlayMeshIps(workingDir, cluster);
  final registryOverlayIp = overlayMeshIps[registryNode.name];

  final deployments = [registryNode].map((node) async {
    // TODO: Use podman if available, fallback to docker
    final sshCmd =
        'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr}';
    // final pipeline =
    //     Script('docker save $image') | Script('$sshCmd "podman load"');
    final manifestPipeline = Script('tar -O -xf $file manifest.json');
    final manifestJson = await manifestPipeline.stdout.text;
    final imageHash = _getHashFromOCIManifest(jsonDecode(manifestJson));

    if (debug) echo('Uploading image...');

    final pipeline = Script('cat $file') | Script('$sshCmd "podman load"');
    await pipeline.stdout.text;

    // final ipCmd = Script(
    //     '$sshCmd "ip -4 addr show flannel-wg | grep -oP \'inet [0-9\\.]*\'"');
    // final tmp = await ipCmd.stdout.text;
    // final registryIp = tmp.replaceFirst('inet ', '');
    echo('Registry IP: $registryOverlayIp');
    if (debug) echo('Pushing image to registry...');

    // After loading the image, push it to the local registry
    final pushCmd = Script(multi([
      '$sshCmd "',
      'podman push \$(podman images --format {{.ID}} $imageHash) $registryOverlayIp:5000/apps/$name:latest &&',
      'podman push \$(podman images --format {{.ID}} $imageHash) $registryOverlayIp:5000/apps/$name:$tag',
      '"'
    ]));
    String tmpOutp = await pushCmd.stdout.text;
    if (debug) echo(tmpOutp);

    final removeCmd = Script(
        '$sshCmd "podman rmi \$(podman images --format {{.ID}} $imageHash)"');
    await removeCmd.stdout.text;

    echo('Published $imageHash in registry on ${node.name}');
  });

  await Future.wait(deployments);
}

Future<void> listImagesInRegistry(
  Directory workingDir,
  Iterable<ClusterNode> cluster,
  ClusterNode registryNode,
) async {
  final overlayMeshIps = await getOverlayMeshIps(workingDir, cluster);
  final registryOverlayIp = overlayMeshIps[registryNode.name];
  final deployments = [registryNode].map((node) async {
    // TODO: Use podman if available, fallback to docker
    final sshCmd =
        'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr}';

    // final ipCmd = Script(
    //     '$sshCmd "ip -4 addr show flannel-wg | grep -oP \'inet [0-9\\.]*\'"');
    // final tmp = await ipCmd.stdout.text;
    // final registryIp = tmp.replaceFirst('inet ', '');
    echo('Registry IP: $registryOverlayIp');

    final pipeline = Script('$sshCmd "docker search $registryOverlayIp:5000/"');
    final res = await pipeline.stdout.text;
    print(res);
  });

  await Future.wait(deployments);
}
// API: https://docker-docs.uclv.cu/registry/spec/api/
// curl -k http://10.10.93.0:5000/v2/_catalog
// curl -s  -w "%{http_code}" -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" http://10.10.93.0:5000/v2/apps/memcached/manifests/latest
// curl -s  -w "%{http_code}" -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" http://10.10.93.0:5000/v2/apps/memcached/tags/list
// podman search 10.10.93.0:5000/apps/memcached
// podman pull 10.10.93.0:5000/apps/memcached:latest