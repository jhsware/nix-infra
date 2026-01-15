# Systemd Credentials Support Analysis for nix-infra

**Date**: January 2026  
**Task**: Analysis of systemd credentials support in nix-infra

## Executive Summary

This document analyzes how nix-infra currently supports systemd credentials and identifies gaps between the implementation and the full systemd credentials specification. The analysis reveals that nix-infra correctly uses `systemd-creds encrypt` for TPM/host-bound encryption on remote nodes. The gap is in **service integration**—secrets are properly encrypted but services don't use `LoadCredentialEncrypted=` to have systemd automatically decrypt them at service activation.

**Key Finding**: The primary improvement opportunity is adding `LoadCredentialEncrypted=` directive generation in NixOS service modules, which would enable automatic decryption at service start and standardized access via `$CREDENTIALS_DIRECTORY`.

## Current Implementation Overview

### Architecture

```
[Local] secrets/ (openssl AES-256-CBC PBKDF2 encrypted)
    ↓ SSH (secret decrypted locally, sent over SSH, re-encrypted on remote)
[Remote] systemd-creds encrypt → /root/secrets/$secretName (TPM/host-bound encrypted)
    ↓ Apps must call systemd-creds decrypt OR use LoadCredentialEncrypted=
[App] Currently: manual decryption required
```

The `deploySecretOnRemote()` function correctly encrypts secrets on the remote host:
```dart
await shell.run('$sshCmd "systemd-creds encrypt - /root/secrets/$secretName"');
```

This creates TPM-bound or host-key-bound encrypted credentials that can only be decrypted on that specific machine.

### Key Components

#### 1. secrets.dart - Core Secret Management

The `secrets.dart` module provides:

| Function | Purpose | Implementation |
|----------|---------|----------------|
| `saveSecret()` | Encrypt and store secrets locally | OpenSSL enc -pbkdf2 with password |
| `readSecret()` | Decrypt local secrets | OpenSSL decryption |
| `deploySecretOnRemote()` | Deploy encrypted to remote node | SSH + `systemd-creds encrypt` (TPM-bound) |
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

1. **Local encryption**: Secrets stored encrypted locally using OpenSSL AES-256-CBC PBKDF2
2. **Remote encryption**: Uses `systemd-creds encrypt` on remote for TPM/host-bound encryption ✅
3. **Variable substitution**: Dynamic values like IPs can be injected at deployment time
4. **Binary support**: Can handle credentials up to 1MB
5. **Cleanup**: Automatically removes secrets that are no longer needed

## Gap Analysis: systemd Credentials Features

### Feature Comparison Matrix

| Feature | systemd Spec | nix-infra Status | Gap |
|---------|--------------|------------------|-----|
| `systemd-creds encrypt` | Encrypt credentials | ✅ **Fully Supported** | None |
| Binary credentials (≤1MB) | Store binary data | ✅ Supported | None |
| Variable substitution | Custom `${}` syntax | ✅ Custom `[%%var%%]` | Different syntax |
| `LoadCredential=` | Load unencrypted file at activation | ❌ Not configured | Service config needed |
| `LoadCredentialEncrypted=` | Load encrypted file at activation | ❌ Not configured | **Service config needed** |
| `SetCredential=` | Literal value in unit file | ❌ Not supported | Low priority |
| `SetCredentialEncrypted=` | Encrypted literal in unit | ❌ Not supported | Medium priority |
| `ImportCredential=` | Auto-search credential stores | ❌ Not supported | Medium priority |
| `/etc/credstore/` | Standard unencrypted store path | ❌ Uses `/root/secrets/` | Easy fix |
| `/etc/credstore.encrypted/` | Standard encrypted store path | ❌ Uses `/root/secrets/` | Easy fix |
| `$CREDENTIALS_DIRECTORY` | Runtime credential access | ❌ Not available | Requires LoadCredential= |
| `ConditionCredential=` | Service conditional on credential | ❌ Not supported | Low priority |
| `AssertCredential=` | Required credential assertion | ❌ Not supported | Low priority |
| `PrivateMounts=` | Namespace isolation for credentials | ❌ Not configured | Medium priority |

### The Integration Gap

The credentials ARE properly encrypted on the remote using `systemd-creds encrypt`. The gap is how services ACCESS these encrypted credentials:

**Current Flow**:
```
1. Secrets deployed to /root/secrets/$secretName (encrypted with systemd-creds)
2. Applications must manually call: systemd-creds decrypt /root/secrets/$secretName -
3. OR applications need custom decryption logic
4. No automatic lifecycle management
```

**Ideal Flow** (with LoadCredentialEncrypted=):
```
1. Secrets deployed to /etc/credstore.encrypted/$secretName.enc (same encryption)
2. Service unit has: LoadCredentialEncrypted=mykey:/etc/credstore.encrypted/mykey.enc
3. systemd automatically decrypts at service start → /run/credentials/myservice/mykey
4. Service reads plaintext from $CREDENTIALS_DIRECTORY/mykey
5. Credentials automatically removed when service stops
```

### Benefits of Adding LoadCredentialEncrypted=

1. **Automatic decryption**: systemd handles decryption at service activation
2. **Lifecycle management**: Credentials only exist in cleartext while service runs
3. **Isolation**: `PrivateMounts=` prevents other processes from accessing
4. **Standardization**: Apps use `$CREDENTIALS_DIRECTORY` consistently
5. **Auditability**: systemd logs credential loading

## Value Assessment

### High Priority Features

| Feature | Value | Effort | ROI |
|---------|-------|--------|-----|
| `LoadCredentialEncrypted=` in NixOS modules | **HIGH** - Automatic decryption | Medium - NixOS service config | ⭐⭐⭐⭐⭐ |
| `$CREDENTIALS_DIRECTORY` support | **HIGH** - Standardized access | Low - Comes with LoadCredential | ⭐⭐⭐⭐⭐ |

### Medium Priority Features

| Feature | Value | Effort | ROI |
|---------|-------|--------|-----|
| Move to `/etc/credstore.encrypted/` | **MEDIUM** - Standards compliance | Low - Path change | ⭐⭐⭐⭐ |
| `PrivateMounts=` configuration | **MEDIUM** - Enhanced isolation | Low - Config addition | ⭐⭐⭐⭐ |
| `ImportCredential=` glob support | **MEDIUM** - Flexible credential discovery | Medium | ⭐⭐⭐ |

### Low Priority Features

| Feature | Value | Effort | ROI |
|---------|-------|--------|-----|
| `SetCredentialEncrypted=` | **LOW** - Inline encrypted values | Medium | ⭐⭐ |
| `ConditionCredential=` | **LOW** - Conditional service start | Low | ⭐⭐ |

## Recommendations

### Phase 1: Service Integration (Recommended First)

**Goal**: Enable automatic credential decryption for services

1. **Add LoadCredentialEncrypted= to NixOS service modules**
   - When deploying NixOS modules, generate appropriate credential loading directives
   - Map secret names to service credential requirements
   - Example:
   ```nix
   systemd.services.myapp = {
     serviceConfig = {
       LoadCredentialEncrypted = "db-password:/root/secrets/myapp-db-password";
       # OR if path changed:
       # LoadCredentialEncrypted = "db-password:/etc/credstore.encrypted/myapp-db-password";
     };
   };
   ```

2. **Update application configurations**
   - Modify apps to read from `$CREDENTIALS_DIRECTORY` instead of calling `systemd-creds decrypt`

3. **Optional: Change deployment path**
   - Move from `/root/secrets/` to `/etc/credstore.encrypted/` for standards compliance

### Phase 2: Enhanced Security

1. Enable `PrivateMounts=true` for credential isolation
2. Add `AssertCredential=` for required credentials

## Implementation Considerations

### Minimal Change Option

The simplest approach is to just add `LoadCredentialEncrypted=` directives to NixOS service configurations, pointing to the existing `/root/secrets/` path:

```nix
LoadCredentialEncrypted = "mykey:/root/secrets/mykey";
```

This requires no changes to `secrets.dart` - only NixOS module configuration.

### Backward Compatibility

- Existing deployments already have encrypted secrets in `/root/secrets/`
- Adding `LoadCredentialEncrypted=` is additive - doesn't break existing apps
- Apps can migrate to `$CREDENTIALS_DIRECTORY` gradually

## Conclusion

nix-infra correctly implements `systemd-creds encrypt` for TPM/host-bound credential encryption. The gap is purely in **service configuration** - adding `LoadCredentialEncrypted=` directives to NixOS service units would enable automatic decryption and standardized credential access.

**Summary**:
- ✅ `systemd-creds encrypt` - **Already implemented correctly**
- 🔲 `LoadCredentialEncrypted=` - Needs NixOS service configuration
- 🔲 `$CREDENTIALS_DIRECTORY` - Comes automatically with LoadCredentialEncrypted=

**Estimated effort**: 1-2 days (NixOS module configuration only, no Dart code changes required)

## Appendix: How Apps Currently Access Secrets

Currently, applications accessing secrets from `/root/secrets/` would need to:

```bash
# Manual decryption (current approach)
SECRET=$(systemd-creds decrypt /root/secrets/myapp-db-password -)
```

With `LoadCredentialEncrypted=` configured:

```bash
# Automatic decryption (desired approach)
SECRET=$(cat "$CREDENTIALS_DIRECTORY/db-password")
```
