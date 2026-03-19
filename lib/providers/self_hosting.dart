import 'dart:io';
import 'package:yaml/yaml.dart';

import 'package:nix_infra/helpers.dart';
import 'package:nix_infra/types.dart';
import 'provider.dart';

/// Configuration for a self-hosted server loaded from servers.yaml
class SelfHostedServerConfig {
  final String name;
  final String? ipAddr;
  final String sshKeyPath;
  final String? description;
  final String? username;
  final String? provider;
  final Map<String, dynamic>? metadata;

  SelfHostedServerConfig({
    required this.name,
    this.ipAddr,
    required this.sshKeyPath,
    this.description,
    this.username,
    this.provider,
    this.metadata,
  });

  /// Whether this server's IP is resolved from a cloud provider at runtime.
  bool get isCloudManaged => provider != null;

  /// Create from a YAML map entry
  factory SelfHostedServerConfig.fromYaml(String name, Map<dynamic, dynamic> yaml) {
    return SelfHostedServerConfig(
      name: name,
      ipAddr: yaml['ip'] as String?,
      sshKeyPath: yaml['ssh_key'] as String,
      description: yaml['description'] as String?,
      username: yaml['username'] as String?,
      provider: yaml['provider'] as String?,
      metadata: yaml['metadata'] != null 
          ? Map<String, dynamic>.from(yaml['metadata'] as Map)
          : null,
    );
  }
}

/// Provider for self-hosted servers defined in a servers.yaml file.
/// 
/// This provider manages servers that are defined in a YAML configuration file.
/// Servers can either have a static IP address (self-hosted) or specify a cloud
/// provider (e.g., "hetzner") to resolve their IP at runtime.
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
///   cloud-server-1:
///     provider: hetzner
///     ssh_key: ./ssh/cloud-key
///     description: Cloud managed server
///
///   db-server-1:
///     ip: 192.168.1.20
///     ssh_key: ./ssh/db-server-1
///     description: Primary database server
/// ```
class SelfHosting implements InfrastructureProvider {
  final Directory _workingDir;
  final Map<String, SelfHostedServerConfig> _servers;
  final Map<String, InfrastructureProvider> _cloudProviders;

  SelfHosting._internal(this._workingDir, this._servers, this._cloudProviders);

  /// Load a SelfHosting provider from a servers.yaml file.
  /// 
  /// The [workingDir] is the directory containing the servers.yaml file.
  /// Relative paths in the configuration (like ssh_key paths) will be
  /// resolved relative to this directory.
  /// 
  /// The optional [cloudProviders] map provides cloud provider instances
  /// keyed by provider name (e.g., "hetzner"). These are used to resolve
  /// IPs for servers that specify a `provider` field instead of a static `ip`.
  static Future<SelfHosting> load(
    Directory workingDir, {
    Map<String, InfrastructureProvider>? cloudProviders,
  }) async {
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
    final providers = cloudProviders ?? {};

    for (final entry in serversYaml.entries) {
      final name = entry.key as String;
      final config = entry.value as YamlMap;
      
      // Validate required fields
      final hasIp = config['ip'] != null;
      final hasProvider = config['provider'] != null;
      
      if (!hasIp && !hasProvider) {
        throw Exception('Server "$name" must have either "ip" or "provider" (found neither)');
      }
      if (hasIp && hasProvider) {
        throw Exception('Server "$name" cannot have both "ip" and "provider"');
      }
      if (config['ssh_key'] == null) {
        throw Exception('Server "$name" is missing required field "ssh_key"');
      }
      
      // Validate that cloud provider is available if specified
      if (hasProvider) {
        final providerName = config['provider'] as String;
        if (!providers.containsKey(providerName)) {
          throw Exception(
            'Server "$name" references cloud provider "$providerName" '
            'but it is not configured. Ensure the required credentials are set '
            '(e.g., HCLOUD_TOKEN for hetzner).',
          );
        }
      }

      servers[name] = SelfHostedServerConfig.fromYaml(
        name, 
        Map<dynamic, dynamic>.from(config),
      );
    }

    return SelfHosting._internal(workingDir, servers, providers);
  }

  /// Check if a servers.yaml file exists in the given directory.
  static Future<bool> hasServersConfig(Directory workingDir) async {
    final configFile = File('${workingDir.path}/servers.yaml');
    return await configFile.exists();
  }

  /// Get the set of cloud provider names referenced in servers.yaml.
  /// 
  /// Returns an empty set if no servers use cloud providers, or if
  /// servers.yaml doesn't exist.
  static Future<Set<String>> getReferencedCloudProviders(Directory workingDir) async {
    final configFile = File('${workingDir.path}/servers.yaml');
    if (!await configFile.exists()) return {};

    final content = await configFile.readAsString();
    final yaml = loadYaml(content);
    if (yaml == null || yaml['servers'] == null) return {};

    final serversYaml = yaml['servers'] as YamlMap;
    final providers = <String>{};
    
    for (final entry in serversYaml.entries) {
      final config = entry.value as YamlMap;
      final provider = config['provider'];
      if (provider != null) {
        providers.add(provider as String);
      }
    }
    
    return providers;
  }

  @override
  String get providerName => 'Self-Hosting';

  @override
  bool get supportsCreateServer => false;
  
  @override
  bool get supportsAddSshKey => false;

  @override
  bool get supportsDestroyServer => false;

  @override
  bool get supportsPlacementGroups => false;

  /// Extract the SSH key name from a path.
  /// 
  /// For example: ./ssh/my-key -> my-key
  String _extractSshKeyName(String sshKeyPath) {
    final parts = sshKeyPath.split('/');
    return parts.last;
  }

  @override
  Future<Iterable<ClusterNode>> getServers({List<String>? only}) async {
    var serverConfigs = _servers.values;
    
    if (only != null) {
      // Check if any requested servers don't exist
      final availableNames = _servers.keys.toSet();
      final requestedNames = only.toSet();
      final missingServers = requestedNames.difference(availableNames);
      
      if (missingServers.isNotEmpty) {
        throw Exception(
          'Server(s) not found in servers.yaml: ${missingServers.join(", ")}\n'
          'Available servers: ${availableNames.join(", ")}'
        );
      }
      
      serverConfigs = serverConfigs.where((s) => only.contains(s.name));
    }

    final nodes = <ClusterNode>[];
    for (final config in serverConfigs) {
      final sshKeyName = _extractSshKeyName(config.sshKeyPath);
      
      // Resolve IP: static from config or dynamic from cloud provider
      String ipAddr;
      if (config.isCloudManaged) {
        final cloudProvider = _cloudProviders[config.provider];
        if (cloudProvider == null) {
          throw Exception(
            'Cloud provider "${config.provider}" not configured for server "${config.name}"',
          );
        }
        final resolvedIp = await cloudProvider.getIpAddr(config.name);
        if (resolvedIp == null) {
          throw Exception(
            'Server "${config.name}" not found in ${config.provider}',
          );
        }
        ipAddr = resolvedIp;
      } else {
        ipAddr = config.ipAddr!;
      }
      
      final node = ClusterNode(
        config.name,
        ipAddr,
        config.name.hashCode, // Use name hash as ID
        sshKeyName,
        sshKeyPath: config.sshKeyPath,
      );
      // Set custom username if specified
      if (config.username != null) {
        node.username = config.username!;
      }
      nodes.add(node);
    }
    
    return nodes;
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
    if (server == null) return null;
    
    if (server.isCloudManaged) {
      final cloudProvider = _cloudProviders[server.provider];
      if (cloudProvider == null) return null;
      return await cloudProvider.getIpAddr(name);
    }
    
    return server.ipAddr;
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
        final sshKeyPath = _resolveSshKeyPathInternal(server.sshKeyPath);
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
  
  /// Internal helper to resolve SSH key path.
  String _resolveSshKeyPathInternal(String sshKeyPath) {
    if (sshKeyPath.startsWith('/')) {
      return sshKeyPath;
    }
    return '${_workingDir.path}/$sshKeyPath';
  }
}
