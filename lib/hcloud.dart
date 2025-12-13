/// @deprecated Use `package:nix_infra/providers/hcloud.dart` instead.
/// 
/// This file is kept for backward compatibility and simply re-exports
/// the HetznerCloud class from its new location in the providers directory.
/// 
/// To migrate:
/// - Replace `import 'package:nix_infra/hcloud.dart'`
/// - With `import 'package:nix_infra/providers/hcloud.dart'`
/// 
/// Or use the unified providers library:
/// `import 'package:nix_infra/providers/providers.dart'`
@Deprecated('Use package:nix_infra/providers/hcloud.dart instead')
export 'providers/hcloud.dart';
