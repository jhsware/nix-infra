import 'dart:io';
import 'package:nix_infra/types.dart';

/// Abstract interface for infrastructure providers.
/// 
/// This interface defines the contract that all providers must implement
/// to work with the nix-infra tooling. Each provider manages a fleet of
/// servers, providing operations for listing, creating, and destroying nodes.
abstract class InfrastructureProvider {
  /// Get all servers managed by this provider.
  /// 
  /// If [only] is provided, returns only servers matching those names.
  Future<Iterable<ClusterNode>> getServers({List<String>? only});

  /// Create a new server with the given parameters.
  /// 
  /// Not all providers support server creation (e.g., self-hosted servers
  /// are pre-existing). Providers that don't support this should throw
  /// [UnsupportedError].
  Future<void> createServer(
    String name,
    String machineType,
    String location,
    String sshKeyName,
    int? placementGroupId,
  );

  /// Destroy a server by its ID.
  /// 
  /// Not all providers support server destruction. Providers that don't
  /// support this should throw [UnsupportedError].
  Future<void> destroyServer(int id);

  /// Get the IP address of a server by name.
  /// 
  /// Returns null if the server is not found.
  Future<String?> getIpAddr(String name);

  /// Add an SSH key to the cloud provider.
  /// 
  /// Not all providers need this (e.g., self-hosted servers already have
  /// SSH keys configured). Providers that don't support this should be
  /// a no-op or throw [UnsupportedError] if it's an error condition.
  Future<void> addSshKeyToCloudProvider(Directory workingDir, String keyName);

  /// Remove an SSH key from the cloud provider.
  /// 
  /// Not all providers need this. Providers that don't support this should
  /// be a no-op or throw [UnsupportedError] if it's an error condition.
  Future<void> removeSshKeyFromCloudProvider(Directory workingDir, String keyName);

  /// Whether this provider supports creating new servers.
  bool get supportsCreateServer;

  /// Whether this provider supports destroying servers.
  bool get supportsDestroyServer;

  /// Whether this provider supports placement groups.
  bool get supportsPlacementGroups;

  /// The name of this provider for display purposes.
  String get providerName;
}

/// Enum representing the available provider types.
enum ProviderType {
  hcloud,
  selfHosting,
}
