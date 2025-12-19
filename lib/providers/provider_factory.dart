import 'dart:io';
import 'package:dotenv/dotenv.dart';

import 'provider.dart';
import 'hcloud.dart';
import 'self_hosting.dart';

/// Factory for creating infrastructure providers.
/// 
/// This factory automatically detects which provider to use based on
/// the presence of configuration files:
/// 
/// 1. If servers.yaml exists and contains server definitions, use SelfHosting
/// 2. Otherwise, if HCLOUD_TOKEN is available, use HetznerCloud
/// 3. If neither is available, throw an error
class ProviderFactory {
  /// Automatically detect and create the appropriate provider.
  /// 
  /// The detection logic:
  /// - If servers.yaml exists in workingDir, use SelfHosting provider
  /// - Otherwise, use HetznerCloud with the provided credentials
  /// 
  /// Parameters:
  /// - [workingDir]: The working directory containing configuration files
  /// - [env]: Environment variables (for HCLOUD_TOKEN)
  /// - [sshKeyName]: The SSH key name to use
  static Future<InfrastructureProvider> autoDetect({
    required Directory workingDir,
    required DotEnv env,
    required String sshKeyName,
  }) async {
    // Check for servers.yaml first
    if (await SelfHosting.hasServersConfig(workingDir)) {
      return await SelfHosting.load(workingDir);
    }

    // Fall back to Hetzner Cloud
    final hcloudToken = env['HCLOUD_TOKEN'];
    if (hcloudToken == null || hcloudToken.isEmpty) {
      throw Exception(
        'No provider configuration found. Either:\n'
        '  1. Create a servers.yaml file in ${workingDir.path} for self-hosted servers, or\n'
        '  2. Set HCLOUD_TOKEN in your environment or .env file for Hetzner Cloud',
      );
    }

    return HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
  }

  /// Create a specific provider by type.
  /// 
  /// This method allows explicitly choosing a provider type regardless
  /// of auto-detection logic.
  static Future<InfrastructureProvider> create({
    required ProviderType type,
    required Directory workingDir,
    DotEnv? env,
    String? sshKeyName,
  }) async {
    switch (type) {
      case ProviderType.selfHosting:
        return await SelfHosting.load(workingDir);
        
      case ProviderType.hcloud:
        if (env == null) {
          throw ArgumentError('env is required for HetznerCloud provider');
        }
        if (sshKeyName == null) {
          throw ArgumentError('sshKeyName is required for HetznerCloud provider');
        }
        final hcloudToken = env['HCLOUD_TOKEN'];
        if (hcloudToken == null || hcloudToken.isEmpty) {
          throw Exception('HCLOUD_TOKEN not found in environment');
        }
        return HetznerCloud(token: hcloudToken, sshKey: sshKeyName);
    }
  }

  /// Check which provider would be selected by auto-detection.
  /// 
  /// Returns the provider type that would be used without actually
  /// creating the provider.
  static Future<ProviderType?> detectProviderType(Directory workingDir, DotEnv env) async {
    if (await SelfHosting.hasServersConfig(workingDir)) {
      return ProviderType.selfHosting;
    }
    
    final hcloudToken = env['HCLOUD_TOKEN'];
    if (hcloudToken != null && hcloudToken.isNotEmpty) {
      return ProviderType.hcloud;
    }
    
    return null;
  }

  /// Get a human-readable description of the detected provider.
  static Future<String> describeDetectedProvider(Directory workingDir, DotEnv env) async {
    final type = await detectProviderType(workingDir, env);
    
    switch (type) {
      case ProviderType.selfHosting:
        return 'Self-Hosting (servers.yaml found)';
      case ProviderType.hcloud:
        return 'Hetzner Cloud (HCLOUD_TOKEN set)';
      case null:
        return 'No provider configured';
    }
  }
}

/// Extension methods for provider-agnostic operations.
extension ProviderOperations on InfrastructureProvider {
  /// Safely attempt to destroy a server, handling providers that don't support it.
  Future<bool> tryDestroyServer(int id) async {
    if (!supportsDestroyServer) {
      return false;
    }
    
    try {
      await destroyServer(id);
      return true;
    } catch (e) {
      if (e is UnsupportedError) {
        return false;
      }
      rethrow;
    }
  }

  /// Safely attempt to create a server, handling providers that don't support it.
  Future<bool> tryCreateServer(
    String name,
    String machineType,
    String location,
    String sshKeyName,
    int? placementGroupId,
  ) async {
    if (!supportsCreateServer) {
      return false;
    }
    
    try {
      await createServer(name, machineType, location, sshKeyName, placementGroupId);
      return true;
    } catch (e) {
      if (e is UnsupportedError) {
        return false;
      }
      rethrow;
    }
  }
}
