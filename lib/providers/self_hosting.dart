import 'dart:io';
import 'package:yaml/yaml.dart';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'provider.dart';

/// Configuration for a self-hosted server loaded from servers.yaml
class SelfHostedServerConfig {
  final String name;
  final String ipAddr;
  final String sshKeyPath;
  final String? description;
  final String? username;
  final Map<String, dynamic>? metadata;

  SelfHostedServerConfig({
    required this.name,
    required this.ipAddr,
    required this.sshKeyPath,
    this.description,
    this.username,
    this.metadata,
  });

  /// Create from a YAML map entry
  factory SelfHostedServerConfig.fromYaml(String name, Map<dynamic, dynamic> yaml) {
    return SelfHostedServerConfig(
      name: name,
      ipAddr: yaml['ip'] as String,
      sshKeyPath: yaml['ssh_key'] as String,
      description: yaml['description'] as String?,
      username: yaml['username'] as String?,
      metadata: yaml['metadata'] != null 
          ? Map<String, dynamic>.from(yaml['metadata'] as Map)
          : null,
    );
  }
}

/// Provider for self-hosted servers defined in a servers.yaml file.
/// 
/// This provider manages pre-existing servers that are defined in a YAML
/// configuration file. Unlike cloud providers, this provider cannot create
/// or destroy servers - it only provides access to the servers defined
/// in the configuration.
/// 
/// Example servers.yaml:
/// ```yaml
/// servers:
///   web-server-1:
///     ip: 192.168.1.10
///     ssh_key: ./ssh/web-server-1
///     description: Primary web server
///     username: root  # optional, defaults to root
///     metadata:       # optional additional data
///       location: rack-1
///       
///   db-server-1:
///     ip: 192.168.1.20
///     ssh_key: ./ssh/db-server-1
///     description: Primary database server
/// ```
class SelfHosting implements InfrastructureProvider {
  final Directory _workingDir;
  final Map<String, SelfHostedServerConfig> _servers;

  SelfHosting._internal(this._workingDir, this._servers);

  /// Load a SelfHosting provider from a servers.yaml file.
  /// 
  /// The [workingDir] is the directory containing the servers.yaml file.
  /// Relative paths in the configuration (like ssh_key paths) will be
  /// resolved relative to this directory.
  static Future<SelfHosting> load(Directory workingDir) async {
    final configFile = File('${workingDir.path}/servers.yaml');
    
    if (!await configFile.exists()) {
      throw Exception('servers.yaml not found in ${workingDir.path}');
    }

    final content = await configFile.readAsString();
    final yaml = loadYaml(content);

    if (yaml == null || yaml['servers'] == null) {
      throw Exception('servers.yaml must contain a "servers" key');
    }

    final serversYaml = yaml['servers'] as YamlMap;
    final servers = <String, SelfHostedServerConfig>{};

    for (final entry in serversYaml.entries) {
      final name = entry.key as String;
      final config = entry.value as YamlMap;
      
      // Validate required fields
      if (config['ip'] == null) {
        throw Exception('Server "$name" is missing required field "ip"');
      }
      if (config['ssh_key'] == null) {
        throw Exception('Server "$name" is missing required field "ssh_key"');
      }

      servers[name] = SelfHostedServerConfig.fromYaml(
        name, 
        Map<dynamic, dynamic>.from(config),
      );
    }

    return SelfHosting._internal(workingDir, servers);
  }

  /// Check if a servers.yaml file exists in the given directory.
  static Future<bool> hasServersConfig(Directory workingDir) async {
    final configFile = File('${workingDir.path}/servers.yaml');
    return await configFile.exists();
  }

  @override
  String get providerName => 'Self-Hosting';

  @override
  bool get supportsCreateServer => false;

  @override
  bool get supportsDestroyServer => false;

  @override
  bool get supportsPlacementGroups => false;

  /// Resolve an SSH key path from the configuration.
  /// 
  /// If the path is relative, it will be resolved relative to the working directory.
  String _resolveSshKeyPath(String sshKeyPath) {
    if (sshKeyPath.startsWith('/')) {
      return sshKeyPath;
    }
    return '${_workingDir.path}/$sshKeyPath';
  }

  /// Extract the SSH key name from a path.
  /// 
  /// For example: ./ssh/my-key -> my-key
  String _extractSshKeyName(String sshKeyPath) {
    final parts = sshKeyPath.split('/');
    return parts.last;
  }

  @override
  Future<Iterable<ClusterNode>> getServers({List<String>? only}) async {
    var servers = _servers.values;
    
    if (only != null) {
      servers = servers.where((s) => only.contains(s.name));
    }

    // Generate a unique ID for each server based on its index
    // Since self-hosted servers don't have cloud IDs, we use the hash of the name
    return servers.map((config) {
      final sshKeyName = _extractSshKeyName(config.sshKeyPath);
      final node = ClusterNode(
        config.name,
        config.ipAddr,
        config.name.hashCode, // Use name hash as ID
        sshKeyName,
      );
      // Set custom username if specified
      if (config.username != null) {
        node.username = config.username!;
      }
      return node;
    });
  }

  @override
  Future<void> createServer(
    String name,
    String machineType,
    String location,
    String sshKeyName,
    int? placementGroupId,
  ) async {
    throw UnsupportedError(
      'Self-hosted provider does not support creating servers. '
      'Add servers manually to servers.yaml instead.',
    );
  }

  @override
  Future<void> destroyServer(int id) async {
    throw UnsupportedError(
      'Self-hosted provider does not support destroying servers. '
      'Remove servers manually from servers.yaml instead.',
    );
  }

  @override
  Future<String?> getIpAddr(String name) async {
    final server = _servers[name];
    return server?.ipAddr;
  }

  @override
  Future<void> addSshKeyToCloudProvider(Directory workingDir, String keyName) async {
    // No-op for self-hosted servers - SSH keys are managed manually
    echo('Self-hosted provider: SSH keys are managed manually, skipping cloud registration.');
  }

  @override
  Future<void> removeSshKeyFromCloudProvider(Directory workingDir, String keyName) async {
    // No-op for self-hosted servers - SSH keys are managed manually
    echo('Self-hosted provider: SSH keys are managed manually, skipping cloud removal.');
  }

  /// Get all server configurations.
  Map<String, SelfHostedServerConfig> get servers => Map.unmodifiable(_servers);

  /// Get a specific server configuration by name.
  SelfHostedServerConfig? getServerConfig(String name) => _servers[name];

  /// Verify SSH connectivity to all configured servers.
  /// 
  /// Returns a map of server names to their connectivity status (true if reachable).
  Future<Map<String, bool>> verifyConnectivity() async {
    final results = <String, bool>{};
    
    for (final server in _servers.values) {
      try {
        final sshKeyPath = _resolveSshKeyPath(server.sshKeyPath);
        final keyFile = File(sshKeyPath);
        
        if (!await keyFile.exists()) {
          echo('WARNING: SSH key not found for ${server.name}: $sshKeyPath');
          results[server.name] = false;
          continue;
        }
        
        // TODO: Add actual SSH connectivity test
        results[server.name] = true;
      } catch (e) {
        results[server.name] = false;
      }
    }
    
    return results;
  }
}
