// =============================================================================
// THIS FILE IS DEPRECATED AND SCHEDULED FOR REMOVAL
// =============================================================================
//
// Please update your imports:
//
// Instead of:  import 'package:nix_infra/hcloud.dart'
// Use:         import 'package:nix_infra/providers/providers.dart'
//
// The HetznerCloud class and all provider functionality has been moved to
// lib/providers/ with a proper abstraction layer.
//
// Migration:
// - Use ProviderFactory.autoDetect() to get the appropriate provider
// - Use InfrastructureProvider interface for provider-agnostic code
// - For HetznerCloud-specific features, type-check: if (provider is HetznerCloud)
//
// This file is kept temporarily for backward compatibility with legacy.dart.
// It will be removed in a future version.
// =============================================================================

@Deprecated('Use package:nix_infra/providers/providers.dart instead')
export 'providers/hcloud.dart';
