import 'dart:convert';
import 'dart:io';
import 'package:nix_infra/helpers.dart';
import 'package:http/http.dart' as http;
import 'package:http/http.dart';

import 'package:nix_infra/types.dart';
import 'provider.dart';

const hetznerApiHost = 'api.hetzner.cloud';
// ignore: constant_identifier_names
const BOOTSTRAP_OS = 'ubuntu-22.04';

class HetznerCloud implements InfrastructureProvider {
  String? _token;
  String? _sshKey;

  HetznerCloud({required String token, required String sshKey}) {
    _token = token;
    _sshKey = sshKey;
  }

  Map<String, String> _getHeaders() {
    final authHeaders = {
      'Authorization': 'Bearer $_token',
      'Content-Type': 'application/json',
    };
    return authHeaders;
  }

  @override
  String get providerName => 'Hetzner Cloud';

  @override
  bool get supportsCreateServer => true;

  @override
  bool get supportsDestroyServer => true;

  @override
  bool get supportsPlacementGroups => true;

  Future<Iterable<PlacementGroup>> getPlacementGroups() async {
    int page = 1;
    List<PlacementGroup> outp = [];
    while (page > 0) {
      final url = Uri.https(
          hetznerApiHost, '/v1/placement_groups', {'page': page.toString()});
      final response = await http.get(url, headers: _getHeaders());
      if (response.statusCode > 399) {
        final body = JsonDecoder().convert(response.body);
        throw Exception(body['error']['message']);
      }

      try {
        final body = JsonDecoder().convert(response.body);
        final tmp = body['placement_groups'].map<PlacementGroup>((inp) => PlacementGroup(
            DateTime.parse(inp['created']),
            inp['id'],
            inp['name'],
            inp['type'])).toList();
        outp.addAll(tmp);
        page = body['meta']['nextPage'] ?? 0;
      } catch (e) {
        // Do nothing
      }
    }

    return outp;
  }

  Future<PlacementGroup> createPlacementGroup(String name) async {
    final url = Uri.https(hetznerApiHost, '/v1/placement_groups');
    final response = await http.post(url,
        headers: _getHeaders(),
        body: jsonEncode({
          'name': name,
          'type': 'spread',
        }));
    if (response.statusCode > 399) {
      final body = JsonDecoder().convert(response.body);
      throw Exception(body['error']['message']);
    }

    final body = JsonDecoder().convert(response.body);
    final placementGroup = body['placement_group'];
    return PlacementGroup(DateTime.parse(placementGroup['created']), placementGroup['id'],
        placementGroup['name'], placementGroup['type']);
  }

  Future<void> destroyPlacementGroup(int id) async {
    final url = Uri.https(hetznerApiHost, '/v1/placement_groups', {'id': id});
    final response = await http.delete(url);
    if (response.statusCode > 399) {
      final body = JsonDecoder().convert(response.body);
      throw Exception(body['error']['message']);
    }
  }

  @override
  Future<Iterable<ClusterNode>> getServers({List<String>? only}) async {
    final url = Uri.https(hetznerApiHost, '/v1/servers');
    List servers = [];
    int totalEntries = -1;
    while (totalEntries == -1 || servers.length < totalEntries) {
      final response = await http.get(url, headers: _getHeaders());
      final body = JsonDecoder().convert(response.body);
      totalEntries = body['meta']['pagination']['total_entries'];
      servers.addAll(body['servers']);
    }
    if (only != null) {
      servers = servers.where((node) => only.contains(node['name'])).toList();
    }

    return servers.map((node) => ClusterNode(
        node['name'], node['public_net']['ipv4']['ip'], node['id'], _sshKey!));
  }

  @override
  Future<void> createServer(String name, String machineType, String location,
      String sshKeyName, int? placementGroupId) async {
    final url = Uri.https(hetznerApiHost, '/v1/servers');
    final response = await http.post(
      url,
      headers: _getHeaders(),
      body: jsonEncode({
        'name': name,
        'server_type': machineType,
        'image': BOOTSTRAP_OS,
        'location': location,
        'ssh_keys': [sshKeyName],
        'public_net': {
          'enable_ipv4': true,
        },
        'placement-group': placementGroupId,
//         'user_data': """#cloud-config
// runcmd:
// - curl https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | PROVIDER=hetznercloud NIX_CHANNEL=nixos-23.05 bash 2>&1 | tee /tmp/infect.log
// """
      }),
    );

    dynamic body;
    try {
      body = JsonDecoder().convert(response.body);
    } catch (e) {
      // Do nothing
    }

    if (response.statusCode > 399) {
      throw Exception(body['error']['message']);
    }
  }

  @override
  Future<void> destroyServer(int id) async {
    final url = Uri.https(hetznerApiHost, '/v1/servers/$id');
    final response = await http.delete(
      url,
      headers: _getHeaders(),
    );

    dynamic body;
    try {
      body = JsonDecoder().convert(response.body);
    } catch (e) {
      // Do nothing
    }

    if (response.statusCode > 399) {
      throw Exception(body['error']['message']);
    }
  }

  @override
  Future<String?> getIpAddr(String name) async {
    final servers = await getServers(only: [name]);
    if (servers.isEmpty) return null;
    return servers.first.ipAddr;
  }

  @override
  Future<void> addSshKeyToCloudProvider(
      Directory workingDir, String keyName) async {
    final url = Uri.https(hetznerApiHost, '/v1/ssh_keys');
    final response = await http.get(
      url,
      headers: _getHeaders(),
    );
    dynamic body = {'ssh_keys': []};
    try {
      body = JsonDecoder().convert(response.body);
    } catch (e) {
      // Do nothing
    }
    final sshKey = body['ssh_keys']?.firstWhere(
      (keyObj) => keyObj['name'] == keyName,
      orElse: () => null,
    );

    if (sshKey == null) {
      final publicKeyPath = '${workingDir.path}/ssh/$keyName.pub';
      final pubKeyBody = await File(publicKeyPath).readAsString();

      final response = await http.post(url,
          headers: _getHeaders(),
          body: jsonEncode({
            'name': keyName,
            'public_key': pubKeyBody,
          }));

      if (response.statusCode == 201) {
        echo('SSH key added successfully.');
      } else {
        final errBody = JsonDecoder().convert(response.body);
        if (errBody['error']['code'] == 'uniqueness_error') {
          echo(errBody['error']['message']);
        } else {
          echo('Failed to add SSH key: ${response.body}');
        }
      }
    }

    // if ! hcloud ssh-key describe $SSH_KEY_NAME 1>/dev/null; then
    //   if [ ! -f ${workingdir.path}/ssh/$SSH_KEY_NAME.pub ]; then
    //     echo "The ssh-key could not be found on this machine, these are available:"
    //     ls $HOME/.ssh/*.pub
    //     exit -1
    //   fi
    //   echo "SSH-key not registered with hetzner cloud, adding..."
    //   hcloud ssh-key create --name $SSH_KEY_NAME --public-key-from-file $HOME/.ssh/$SSH_KEY_NAME.pub
    // fi
  }

  @override
  Future<void> removeSshKeyFromCloudProvider(
      Directory workingDir, String keyName) async {
    final url = Uri.https(hetznerApiHost, '/v1/ssh_keys');

    final response = await http.get(
      url,
      headers: _getHeaders(),
    );
    dynamic body = {'ssh_keys': []};
    try {
      body = JsonDecoder().convert(response.body);
    } catch (e) {
      // Do nothing
    }
    // TODO: Should we check that we have a matching publickey so
    // we don't remove one by mistake?
    final sshKey = body['ssh_keys']?.firstWhere(
      (keyObj) => keyObj['name'] == keyName,
      orElse: () => null,
    );

    if (sshKey != null) {
      final url = Uri.https(hetznerApiHost, '/v1/ssh_keys/${sshKey['id']}');
      final response = await http.delete(
        url,
        headers: _getHeaders(),
      );

      if (response.statusCode == 204) {
        echo('SSH key removed successfully.');
      } else {
        echo('Failed to remove SSH key: ${response.statusCode.toString()}');
      }
    } else {
      echo('No SSH key named $keyName was found');
    }
  }

  Future<dynamic> getServerAction(ClusterNode node, String command) async {
    final url = Uri.https(hetznerApiHost, '/v1/servers/${node.id}/actions');
    final response = await http.get(
      url,
      headers: _getHeaders(),
    );

    dynamic body = {'actions': []};
    try {
      body = JsonDecoder().convert(response.body);
    } catch (e) {
      // Do nothing
    }

    if (response.statusCode > 399) {
      throw Exception(body['error']['message']);
    }

    return body['actions']
        ?.firstWhere((action) => action['command'] == command);
  }

  Future<int> getCpu(ClusterNode node, {bool debug = false}) async {
    // TODO: Fix this, we are getting an error: "Bad State"
    final now = DateTime.now();
    final params = {
      'type': 'cpu',
      'start': now.subtract(Duration(seconds: 1)).toIso8601String(),
      'end': now.toIso8601String(),
      'step': '1',
    };
    final url =
        Uri.https(hetznerApiHost, '/v1/servers/${node.id}/metrics', params);
    if (debug) echoDebug(url.toString());

    Response? response;
    dynamic body;
    try {
      response = await http.get(
        url,
        headers: _getHeaders(),
      );
      body = JsonDecoder().convert(response.body);
    } catch (e) {
      // Do nothing
    }

    if (response == null) {
      throw Exception('Could not get CPU metrics');
    }

    if (response.statusCode > 399) {
      throw Exception(body['error']['message']);
    }

    final [_, cpu] = body?['metrics']?['time_series']?['name_of_timeseries']
                ?['values']
            ?.first ??
        [];
    if (cpu == null) {
      return 0;
    } else {
      return int.parse(cpu);
    }
  }
}
