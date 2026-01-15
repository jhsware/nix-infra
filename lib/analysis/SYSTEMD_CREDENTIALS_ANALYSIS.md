# Systemd Credentials Support Analysis for nix-infra

**Date**: January 2026  
**Task**: Analysis of systemd credentials support in nix-infra

## Executive Summary

This document analyzes how nix-infra currently supports systemd credentials and identifies gaps between the implementation and the full systemd credentials specification. The analysis reveals that while nix-infra has solid foundations for secret management using `systemd-creds encrypt`, there is a critical gap in service integration—secrets are deployed but services don't use the standard systemd credential loading mechanism.

**Key Finding**: The primary improvement opportunity is adding `LoadCredentialEncrypted=` directive generation in NixOS service modules, which would enable proper credential lifecycle management and standardized access via `$CREDENTIALS_DIRECTORY`.

## Current Implementation Overview

### Architecture

```
[Local] secrets/ (openssl AES-256-CBC PBKDF2 encrypted)
    ↓ SSH
[Remote] systemd-creds encrypt → /root/secrets/*.enc
    ↓ Manual access
[App] reads /root/secrets/* directly
```

### Key Components

#### 1. secrets.dart - Core Secret Management

The `secrets.dart` module provides:

| Function | Purpose | Implementation |
|----------|---------|----------------|
| `saveSecret()` | Encrypt and store secrets locally | OpenSSL enc -pbkdf2 with password |
| `readSecret()` | Decrypt local secrets | OpenSSL decryption |
| `deploySecretOnRemote()` | Deploy encrypted to remote node | SSH + `systemd-creds encrypt` |
| `syncSecrets()` | Sync expected secrets to node | Deploy needed, remove unused |

**Variable Substitution**: Supports `[%%var%%]` syntax for dynamic values like IP addresses and hostnames.

#### 2. cluster_node.dart - Deployment Integration

- Integrates secret sync into deployment workflow (`deployAppsOnNode`)
- Discovers expected secrets from NixOS configuration files
- Deploys secrets to `/root/secrets/` directory
- Cleans up unused secrets

#### 3. helpers.dart - Supporting Utilities

- `substitute()` function for variable replacement in secret content
- `sftpSend()` with secret detection via `expectedSecrets` parameter

### What Works Well

1. **Encryption at rest**: Secrets are stored encrypted locally using OpenSSL
2. **Secure deployment**: Uses `systemd-creds encrypt` on remote for TPM/host-bound encryption
3. **Variable substitution**: Dynamic values like IPs can be injected at deployment time
4. **Binary support**: Can handle credentials up to 1MB (OpenSSL handles binary data)
5. **Cleanup**: Automatically removes secrets that are no longer needed

## Gap Analysis: systemd Credentials Features

### Feature Comparison Matrix

| Feature | systemd Spec | nix-infra Status | Gap |
|---------|--------------|------------------|-----|
| `systemd-creds encrypt` | Encrypt credentials | ✅ Supported | None |
| Binary credentials (≤1MB) | Store binary data | ✅ Supported | None |
| Variable substitution | Custom `${}` syntax | ✅ Custom `[%%var%%]` | Different syntax |
| `LoadCredential=` | Load unencrypted file at activation | ❌ Not used | **Critical** |
| `LoadCredentialEncrypted=` | Load encrypted file at activation | ❌ Not used | **Critical** |
| `SetCredential=` | Literal value in unit file | ❌ Not supported | Low priority |
| `SetCredentialEncrypted=` | Encrypted literal in unit | ❌ Not supported | Medium priority |
| `ImportCredential=` | Auto-search credential stores | ❌ Not supported | Medium priority |
| `/etc/credstore/` | Standard unencrypted store path | ❌ Uses `/root/secrets/` | Easy fix |
| `/etc/credstore.encrypted/` | Standard encrypted store path | ❌ Uses `/root/secrets/` | Easy fix |
| `$CREDENTIALS_DIRECTORY` | Runtime credential access | ❌ Not available | **Critical** |
| `ConditionCredential=` | Service conditional on credential | ❌ Not supported | Low priority |
| `AssertCredential=` | Required credential assertion | ❌ Not supported | Low priority |
| `PrivateMounts=` | Namespace isolation for credentials | ❌ Not configured | Medium priority |
| AF_UNIX socket credentials | Dynamic credential delivery | ❌ Not supported | Low priority |
| System credentials (hypervisor) | Container/VM credentials | ❌ Not applicable | N/A |

### Critical Gap: No Service Integration

The most significant issue is the disconnect between secret deployment and service consumption:

**Current Flow** (suboptimal):
```
1. Secrets deployed to /root/secrets/*.enc
2. Applications must manually decrypt and read from /root/secrets/
3. No integration with systemd credential lifecycle
4. No $CREDENTIALS_DIRECTORY for standardized access
```

**Ideal Flow** (systemd-native):
```
1. Secrets deployed to /etc/credstore.encrypted/*.enc
2. Service unit has LoadCredentialEncrypted=myapp.key:/etc/credstore.encrypted/myapp-key.enc
3. systemd decrypts and mounts to /run/credentials/myapp.service/
4. Service accesses via $CREDENTIALS_DIRECTORY/myapp.key
5. Credentials automatically cleaned up when service stops
```

### Benefits of Proper Integration

1. **Security**: Credentials exist in cleartext only while service runs
2. **Isolation**: `PrivateMounts=` prevents other processes from accessing
3. **Lifecycle**: Automatic cleanup when service stops
4. **Standardization**: Apps use `$CREDENTIALS_DIRECTORY` consistently
5. **Auditability**: systemd logs credential loading

## Value Assessment

### High Priority Features

| Feature | Value | Effort | ROI |
|---------|-------|--------|-----|
| `LoadCredentialEncrypted=` in NixOS modules | **HIGH** - Enables proper credential lifecycle | Medium - Requires template/module changes | ⭐⭐⭐⭐⭐ |
| Service unit credential configuration | **HIGH** - Completes the integration | Medium - Per-service configuration | ⭐⭐⭐⭐⭐ |
| `$CREDENTIALS_DIRECTORY` support | **HIGH** - Standardized access pattern | Low - Comes with LoadCredential | ⭐⭐⭐⭐⭐ |

### Medium Priority Features

| Feature | Value | Effort | ROI |
|---------|-------|--------|-----|
| Move to `/etc/credstore.encrypted/` | **MEDIUM** - Standards compliance | Low - Path change | ⭐⭐⭐⭐ |
| `PrivateMounts=` configuration | **MEDIUM** - Enhanced isolation | Low - Config addition | ⭐⭐⭐⭐ |
| `ImportCredential=` glob support | **MEDIUM** - Flexible credential discovery | Medium - NixOS module work | ⭐⭐⭐ |
| `ConditionCredential=` | **LOW** - Conditional service start | Low - Simple addition | ⭐⭐⭐ |

### Low Priority Features

| Feature | Value | Effort | ROI |
|---------|-------|--------|-----|
| `SetCredentialEncrypted=` | **LOW** - Inline encrypted values | Medium | ⭐⭐ |
| AF_UNIX socket credentials | **LOW** - Dynamic credential API | High - Architecture change | ⭐ |
| System credentials | **N/A** - Hypervisor/container specific | N/A | N/A |

## Recommendations

### Phase 1: Core Integration (Recommended First)

**Goal**: Enable proper systemd credential loading for services

1. **Modify secret deployment path**
   - Change from `/root/secrets/` to `/etc/credstore.encrypted/`
   - Minimal code change in `secrets.dart`

2. **Add LoadCredentialEncrypted= generation**
   - When deploying NixOS modules, generate appropriate credential loading directives
   - Map secret names to service credential requirements
   - Example NixOS service config:
   ```nix
   systemd.services.myapp = {
     serviceConfig = {
       LoadCredentialEncrypted = "db-password:/etc/credstore.encrypted/myapp-db-password.enc";
       PrivateMounts = true;
     };
   };
   ```

3. **Update application configurations**
   - Modify apps to read from `$CREDENTIALS_DIRECTORY` instead of `/root/secrets/`

### Phase 2: Enhanced Security

1. Enable `PrivateMounts=true` for credential isolation
2. Add `AssertCredential=` for required credentials
3. Add `ConditionCredential=` for optional credentials

### Phase 3: Standards Compliance

1. Support `ImportCredential=` for glob patterns
2. Consider `SetCredentialEncrypted=` for static inline values

## Implementation Considerations

### Backward Compatibility

- Existing deployments use `/root/secrets/` - migration needed
- Applications hardcoded to read from `/root/secrets/` must be updated
- Consider parallel deployment during transition

### NixOS Module Generation

The key implementation challenge is generating NixOS service configurations with appropriate credential loading. Options:

1. **Template-based**: Add `LoadCredentialEncrypted=` to module templates
2. **Dynamic generation**: Generate from secret registry
3. **Convention-based**: Derive credential names from service names

### Testing Strategy

1. Test credential loading with simple service
2. Verify `$CREDENTIALS_DIRECTORY` accessibility
3. Confirm cleanup on service stop
4. Test `PrivateMounts=` isolation

## Conclusion

The nix-infra project has a solid foundation for secret management but lacks the final integration step that would make it fully systemd-native. The critical missing piece is generating `LoadCredentialEncrypted=` directives in service configurations.

**Recommended Priority**:
1. ✅ (Already done) `systemd-creds encrypt` for credential encryption
2. 🔲 (High priority) `LoadCredentialEncrypted=` service integration
3. 🔲 (Medium priority) Standard credential store paths
4. 🔲 (Low priority) Advanced features like `ImportCredential=`

The estimated effort for Phase 1 (core integration) is approximately 2-3 days of development work, with significant security and operational benefits.

## Appendix: systemd Credentials Reference

### Key systemd-creds Commands

```bash
# Encrypt a credential
systemd-creds encrypt - /etc/credstore.encrypted/myapp.enc <<<"secret"

# Decrypt a credential (for testing)
systemd-creds decrypt /etc/credstore.encrypted/myapp.enc -

# List credentials
systemd-creds list
```

### NixOS Service Configuration Pattern

```nix
systemd.services.example = {
  description = "Example service with credentials";
  wantedBy = [ "multi-user.target" ];
  
  serviceConfig = {
    ExecStart = "${pkgs.example}/bin/example";
    
    # Load encrypted credential
    LoadCredentialEncrypted = [
      "api-key:/etc/credstore.encrypted/example-api-key.enc"
      "db-password:/etc/credstore.encrypted/example-db-password.enc"
    ];
    
    # Security hardening
    PrivateMounts = true;
    
    # Optional: Only start if credential exists
    ConditionCredential = "api-key";
  };
};
```

### Environment Access in Service

```bash
# Access credentials in service script
cat "$CREDENTIALS_DIRECTORY/api-key"
cat "$CREDENTIALS_DIRECTORY/db-password"
```
