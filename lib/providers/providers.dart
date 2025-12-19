/// Infrastructure providers for nix-infra.
/// 
/// This library provides a unified interface for managing server infrastructure
/// across different providers. Currently supported providers:
/// 
/// - **HetznerCloud**: Managed cloud servers on Hetzner Cloud
/// - **SelfHosting**: Pre-existing servers defined in servers.yaml
/// 
/// ## Usage
/// 
/// ### Auto-detection (recommended)
/// 
/// ```dart
/// import 'package:nix_infra/providers/providers.dart';
/// 
/// final provider = await ProviderFactory.autoDetect(
///   workingDir: workingDir,
///   env: env,
///   sshKeyName: 'my-key',
/// );
/// 
/// final servers = await provider.getServers();
/// ```
/// 
/// ### Explicit provider selection
/// 
/// ```dart
/// // Use self-hosted servers
/// final provider = await ProviderFactory.create(
///   type: ProviderType.selfHosting,
///   workingDir: workingDir,
/// );
/// 
/// // Use Hetzner Cloud
/// final provider = await ProviderFactory.create(
///   type: ProviderType.hcloud,
///   workingDir: workingDir,
///   env: env,
///   sshKeyName: 'my-key',
/// );
/// ```
/// 
/// ## Adding new providers
/// 
/// To add a new provider:
/// 
/// 1. Create a new file in the providers directory (e.g., `my_provider.dart`)
/// 2. Implement the `InfrastructureProvider` interface
/// 3. Add a new entry to the `ProviderType` enum
/// 4. Update `ProviderFactory` to support the new provider
/// 5. Export the new provider from this file
library providers;

export 'provider.dart';
export 'provider_factory.dart';
export 'hcloud.dart';
export 'self_hosting.dart';
