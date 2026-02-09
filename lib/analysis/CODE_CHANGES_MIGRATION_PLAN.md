# Code Changes Migration Plan: Defense-in-Depth SSH Architecture

**Document Version:** 1.0  
**Status:** Implementation Planning  
**Last Updated:** 2026-02-09

---

## Overview

This document details **all code changes** required to migrate from root SSH user to the defense-in-depth nixinfra user architecture. The changes are organized by category, with exact file locations and before/after examples.

**Total Changes:** ~40 locations across 10 files  
**Complexity:** Low-Medium (mostly find-and-replace + path updates)  
**Risk:** Low (changes are localized and testable)

---

## Summary of Changes by Category

| Category | Files Affected | Changes | Complexity |
|----------|----------------|---------|------------|
| 1. Default Username | 1 (lib/types.dart) | 1 change | ✅ Trivial |
| 2. Hardcoded `username: 'root'` | 1 (lib/certificates.dart) | 1 change | ✅ Trivial |
| 3. Shell SSH Commands (hardcoded `root@`) | 4 files | 8 changes | ⚠️ Medium |
| 4. Remote `/root/` Paths | 7 files | 30+ changes | ⚠️ Medium |
| 5. Comment References to `/root/` | 2 files | 5 changes | ✅ Trivial |
| 6. MCP Server Blacklist | 1 file | 1 change | ✅ Trivial |

---

## Category 1: Default Username

### Change #1: lib/types.dart (Line 26)

**Current Code:**
```dart
class ClusterNode {
  int id;
  String name;
  String ipAddr;
  String username = 'root';  // ← Change this
  String sshKeyName;
  // ...
}
```

**New Code:**
```dart
class ClusterNode {
  int id;
  String name;
  String ipAddr;
  String username = 'nixinfra';  // ← Changed
  String sshKeyName;
  // ...
}
```

**Rationale:**  
- This is the default for new deployments
- Backward compatibility: Existing code can still override via YAML `username: root`
- Single point of truth for username default

**Testing:**
```dart
// Verify default works
final node = ClusterNode('test', '10.0.0.1', 1, 'key');
assert(node.username == 'nixinfra');
```

---

## Category 2: Hardcoded username: 'root'

### Change #2: lib/certificates.dart (Line 350)

**Current Code:**
```dart
Future<void> deployEtcdCertsOnClusterNode(
  Directory workingDir,
  Iterable<ClusterNode> nodes,
  Iterable<CertType> certs, {
  bool debug = false,
}) async {
  for (final node in nodes) {
    // ...
    echo('Deploying certs to ${node.name} (${node.ipAddr})');
    final sshClient = SSHClient(
      await SSHSocket.connect(node.ipAddr, 22),
      username: 'root',  // ← Hardcoded! Should use node.username
      identities: [
        ...SSHKeyPair.fromPem(await getSshKeyAsPem(workingDir, node.sshKeyName))
      ],
    );
```

**New Code:**
```dart
    final sshClient = SSHClient(
      await SSHSocket.connect(node.ipAddr, 22),
      username: node.username,  // ← Changed to use node.username
      identities: [
        ...SSHKeyPair.fromPem(await getSshKeyAsPem(workingDir, node.sshKeyName))
      ],
    );
```

**Rationale:**  
- Consistency: All other SSH clients use `node.username`
- Respects per-node username configuration
- Backward compatible (node.username defaults to 'root' if not overridden)

**Impact:** Certificate deployment respects node's configured username

---

## Category 3: Shell SSH Commands (Hardcoded `root@`)

These are the most complex changes because they involve injecting the `node.username` variable into shell command strings. The pattern is:

**Before:**
```dart
'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "command"'
```

**After:**
```dart
'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no ${node.username}@${node.ipAddr} "command"'
```

### Change #3: lib/provision.dart (Line 139)

**Location:** `installNixos()` function

**Current Code (SFTP write):**
```dart
final installScript = """#!/usr/bin/env bash
echo "mute=on"
curl -s https://raw.githubusercontent.com/jhsware/nixos-infect/refs/heads/master/nixos-infect | NO_REBOOT=true NIX_CHANNEL=$nixChannel bash -x $muteUnlessDebug;

# Make sure we use custom configuration on reboot
cp -f /root/configuration.nix /etc/nixos/configuration.nix;  // ← Needs path update too
// ...
""";

// ...
await sftpWrite(sftp, installScript, '/root/install.sh');  // ← Path change
```

**New Code:**
```dart
// NOTE: The install.sh script now uses staging area
// The bootstrap process needs to be updated to:
// 1. Upload install script to ~/install.sh (user-writable)
// 2. The script copies from ~/staging/ to /etc/nixos/ after upgrade
// 3. This is done via sudo which is whitelisted

final installScript = """#!/usr/bin/env bash
echo "mute=on"
curl -s https://raw.githubusercontent.com/jhsware/nixos-infect/refs/heads/master/nixos-infect | NO_REBOOT=true NIX_CHANNEL=$nixChannel bash -x $muteUnlessDebug;

# Make sure we use custom configuration on reboot
# File was copied to staging by SFTP, now copy to /etc/nixos/ with sudo
sudo cp -f /home/nixinfra/staging/configuration.nix /etc/nixos/configuration.nix;
// ...
""";

// ...
await sftpWrite(sftp, installScript, '/home/nixinfra/install.sh');  // ← Path change
```

**Rationale:**  
- Bootstrap still uses root credentials (provided by cloud provider)
- After NixOS boots, root access is disabled
- Staging area strategy handles files destined for /etc/nixos/

**Note:** This is a **bootstrap operation** using temporary root access. Special case.

---

### Change #4: lib/provision.dart (Line 142)

**Location:** `installNixos()` function

**Current Code:**
```dart
await sftpSend(
    sftp, '${workingDir.path}/configuration.nix', '/root/configuration.nix',
    substitutions: {
      'nixVersion': nixVersion,
      'nodeName': node.name,
      'sshKey': authorizedKey,
    });
```

**New Code:**
```dart
await sftpSend(
    sftp, '${workingDir.path}/configuration.nix', '/home/nixinfra/staging/configuration.nix',
    substitutions: {
      'nixVersion': nixVersion,
      'nodeName': node.name,
      'sshKey': authorizedKey,
    });
```

**Rationale:**  
- Bootstrap temporary area during installation
- Copied to /etc/nixos/ by install script
- Respects staging area strategy

---

### Change #5: lib/provision.dart (Line 202)

**Location:** `installNixos()` function

**Current Code:**
```dart
await shell.run(
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "bash -s " < /root/install.sh');
```

**New Code:**
```dart
await shell.run(
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "bash -s " < /home/nixinfra/install.sh');
```

**Rationale:**  
- Bootstrap phase: still using root (temporary)
- Path change: script is in staging area after provisioning

---

### Change #6: lib/provision.dart (Line 225)

**Location:** `rebuildNixos()` function

**Current Code:**
```dart
await shell.run(
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "nixos-rebuild switch --fast 2>/dev/null"');
```

**New Code:**
```dart
await shell.run(
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no ${node.username}@${node.ipAddr} "nixos-rebuild switch --fast 2>/dev/null"');
```

**Rationale:**  
- Post-bootstrap operation: uses nixinfra user
- Respects node.username configuration
- Command is routed through gate script

---

### Change #7: lib/provision.dart (Line 237)

**Location:** `rebootToNixos()` function

**Current Code:**
```dart
final script =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "reboot 2>/dev/null"';
```

**New Code:**
```dart
final script =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "reboot 2>/dev/null"';
```

**Note:** This is a **bootstrap operation**. Reboot is sent via root because:
1. Happens immediately after nixos-infect
2. NixOS hasn't booted yet
3. nixinfra user doesn't exist yet

**Action:** Leave as-is (root@ is correct for bootstrap phase)

---

### Change #8: lib/provision.dart (Line 298)

**Location:** `rebuildNixos()` function

**Current Code:**
```dart
final script =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "nixos-rebuild switch --fast"';
```

**New Code:**
```dart
final script =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no ${node.username}@${node.ipAddr} "nixos-rebuild switch --fast"';
```

**Rationale:**  
- Post-bootstrap operation
- Uses nixinfra user
- Routed through gate script

---

### Change #9: lib/docker_registry.dart (Line 33)

**Location:** `publishImageToRegistry()` function

**Current Code:**
```dart
final sshCmd =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr}';
```

**New Code:**
```dart
final sshCmd =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no ${node.username}@${node.ipAddr}';
```

**Rationale:**  
- Post-bootstrap operation
- Uses node.username (defaults to nixinfra)
- Commands are routed through gate script

---

### Change #10: lib/docker_registry.dart (Line 82)

**Location:** `listImagesInRegistry()` function

**Current Code:**
```dart
final sshCmd =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr}';
```

**New Code:**
```dart
final sshCmd =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no ${node.username}@${node.ipAddr}';
```

**Rationale:**  
- Same as above

---

### Change #11: lib/secrets.dart (Line 103)

**Location:** `deploySecretOnRemote()` function

**Current Code:**
```dart
final sshCmd =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr}';
```

**New Code:**
```dart
final sshCmd =
    'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no ${node.username}@${node.ipAddr}';
```

**Rationale:**  
- Uses node.username
- Secrets deployed via nixinfra user

---

## Category 4: Remote `/root/` Paths

These are path replacements. All `/root/` → `/home/nixinfra/` or `/home/nixinfra/staging/` depending on context.

### Path Migration Reference

| Old Path | New Path | Context |
|----------|----------|---------|
| `/root/action.sh` | `/home/nixinfra/action.sh` | Ephemeral script |
| `/root/certs/` | `/home/nixinfra/certs/` | User-writable certs |
| `/root/secrets/` | `/home/nixinfra/secrets/` | User-writable secrets |
| `/root/uploads/` | `/home/nixinfra/uploads/` | User uploads |
| `/root/install.sh` | `/home/nixinfra/install.sh` | Bootstrap temporary |
| `/root/configuration.nix` | `/home/nixinfra/staging/configuration.nix` | Staging for /etc/nixos/ |

---

### Change #12: lib/ssh.dart (Line 146)

**Location:** `runActionScriptOverSsh()` function

**Current Code:**
```dart
await sftpSend(sftp, script.path, '/root/action.sh');
```

**New Code:**
```dart
await sftpSend(sftp, script.path, '/home/nixinfra/action.sh');
```

**Rationale:**  
- Action scripts are temporary
- User-writable directory

---

### Change #13: lib/ssh.dart (Line 151)

**Location:** `runActionScriptOverSsh()` function

**Current Code:**
```dart
final res = await sshClient.run(
  '$envVarsToRemote bash /root/action.sh $cmd',
);
```

**New Code:**
```dart
final res = await sshClient.run(
  '$envVarsToRemote bash /home/nixinfra/action.sh $cmd',
);
```

**Rationale:**  
- Matches new script location

---

### Change #14: lib/ssh.dart (Line 155)

**Location:** `runActionScriptOverSsh()` function

**Current Code:**
```dart
await sshClient.run('rm /root/action.sh');
```

**New Code:**
```dart
await sshClient.run('rm /home/nixinfra/action.sh');
```

**Rationale:**  
- Cleanup of temporary script

---

### Change #15: lib/ssh.dart (Line 136)

**Location:** `runActionScriptOverSsh()` function (debug output)

**Current Code:**
```dart
echoDebug("Command to run: /root/action.sh $cmd");
```

**New Code:**
```dart
echoDebug("Command to run: /home/nixinfra/action.sh $cmd");
```

**Rationale:**  
- Debug logging only (no functionality impact)

---

### Change #16: lib/certificates.dart (Line 357)

**Location:** `deployEtcdCertsOnClusterNode()` function

**Current Code:**
```dart
final stat =
    await sftp.stat('/root/certs').catchError((err) => SftpFileAttrs());
if (!stat.isDirectory) {
  await sftp.mkdir('/root/certs');
}
```

**New Code:**
```dart
final stat =
    await sftp.stat('/home/nixinfra/certs').catchError((err) => SftpFileAttrs());
if (!stat.isDirectory) {
  await sftp.mkdir('/home/nixinfra/certs');
}
```

**Rationale:**  
- Certificate storage directory
- User-writable path

---

### Change #17: lib/certificates.dart (Line 363)

**Location:** `deployEtcdCertsOnClusterNode()` function

**Current Code:**
```dart
final absFilePath = '/root/certs/${fileName(file)}';
```

**New Code:**
```dart
final absFilePath = '/home/nixinfra/certs/${fileName(file)}';
```

**Rationale:**  
- Matches new certs directory

---

### Change #18: lib/certificates.dart (Line 381-382)

**Location:** `deployEtcdCertsOnClusterNode()` function (chmod commands)

**Current Code:**
```dart
final script = """\\
chmod 400 /root/certs/*
chmod 700 /root/certs
exit 0;
""";
```

**New Code:**
```dart
final script = """\\
chmod 400 /home/nixinfra/certs/*
chmod 700 /home/nixinfra/certs
exit 0;
""";
```

**Rationale:**  
- Permission setting for cert directory

---

### Change #19: lib/cluster_node.dart (Line 271-273)

**Location:** `registerClusterNode()` function

**Current Code:**
```dart
await sshClient.run('''
  export ETCDCTL_DIAL_TIMEOUT=3s
  export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem
  export ETCDCTL_CERT=/root/certs/${node.name}-client-tls.cert.pem
  export ETCDCTL_KEY=/root/certs/${node.name}-client-tls.key.pem
  export ETCDCTL_API=3
  etcdctl --endpoints=https://${ctrlNodes.first.ipAddr}:2379 put /cluster/nodes/${node.name} "$jsonPayload"
''', stdout: true, stderr: true);
```

**New Code:**
```dart
await sshClient.run('''
  export ETCDCTL_DIAL_TIMEOUT=3s
  export ETCDCTL_CACERT=/home/nixinfra/certs/ca-chain.cert.pem
  export ETCDCTL_CERT=/home/nixinfra/certs/${node.name}-client-tls.cert.pem
  export ETCDCTL_KEY=/home/nixinfra/certs/${node.name}-client-tls.key.pem
  export ETCDCTL_API=3
  etcdctl --endpoints=https://${ctrlNodes.first.ipAddr}:2379 put /cluster/nodes/${node.name} "$jsonPayload"
''', stdout: true, stderr: true);
```

**Rationale:**  
- etcdctl reads certificates from new location

---

### Change #20: lib/cluster_node.dart (Line 295-296)

**Location:** `unregisterClusterNode()` function

**Current Code:**
```dart
await sshClient.run('''
  export ETCDCTL_DIAL_TIMEOUT=3s
  export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem
  export ETCDCTL_CERT=/root/certs/\$(hostname)-client-tls.cert.pem
  export ETCDCTL_KEY=/root/certs/\$(hostname)-client-tls.key.pem
  export ETCDCTL_API=3
  etcdctl --endpoints=https://${ctrlNodes.first.ipAddr}:2379 del /cluster/nodes/\$(hostname)
  systemctl stop flannel
''');
```

**New Code:**
```dart
await sshClient.run('''
  export ETCDCTL_DIAL_TIMEOUT=3s
  export ETCDCTL_CACERT=/home/nixinfra/certs/ca-chain.cert.pem
  export ETCDCTL_CERT=/home/nixinfra/certs/\$(hostname)-client-tls.cert.pem
  export ETCDCTL_KEY=/home/nixinfra/certs/\$(hostname)-client-tls.key.pem
  export ETCDCTL_API=3
  etcdctl --endpoints=https://${ctrlNodes.first.ipAddr}:2379 del /cluster/nodes/\$(hostname)
  systemctl stop flannel
''');
```

**Rationale:**  
- Same as registerClusterNode()

---

### Change #21: lib/secrets.dart (Line 149)

**Location:** `syncSecrets()` function

**Current Code:**
```dart
final sftp = await sshClient.sftp();
await sftpMkDir(sftp, '/root/secrets');
```

**New Code:**
```dart
final sftp = await sshClient.sftp();
await sftpMkDir(sftp, '/home/nixinfra/secrets');
```

**Rationale:**  
- Secrets storage directory
- User-writable path

---

### Change #22: lib/secrets.dart (Line 176)

**Location:** `syncSecrets()` function

**Current Code:**
```dart
final listOfFiles = await sftp.listdir('/root/secrets');
```

**New Code:**
```dart
final listOfFiles = await sftp.listdir('/home/nixinfra/secrets');
```

**Rationale:**  
- List secrets in new location

---

### Change #23: lib/secrets.dart (Line 179-180)

**Location:** `syncSecrets()` function

**Current Code:**
```dart
echo('/root/secrets/${file.filename}');
await sftp.remove('/root/secrets/${file.filename}');
```

**New Code:**
```dart
echo('/home/nixinfra/secrets/${file.filename}');
await sftp.remove('/home/nixinfra/secrets/${file.filename}');
```

**Rationale:**  
- Cleanup of unused secrets

---

### Change #24: lib/helpers.dart (Line 224-226)

**Location:** `getOverlayMeshIps()` function

**Current Code:**
```dart
final res = await sshClient.run('''
    export ETCDCTL_DIAL_TIMEOUT=3s
    export ETCDCTL_CACERT=/root/certs/ca-chain.cert.pem
    export ETCDCTL_CERT=/root/certs/${etcdNode.name}-client-tls.cert.pem
    export ETCDCTL_KEY=/root/certs/${etcdNode.name}-client-tls.key.pem
    export ETCDCTL_API=3
    etcdctl --endpoints=https://${etcdNode.ipAddr}:2379 get --prefix /coreos.com/network/subnets
  ''', stdout: true, stderr: true);
```

**New Code:**
```dart
final res = await sshClient.run('''
    export ETCDCTL_DIAL_TIMEOUT=3s
    export ETCDCTL_CACERT=/home/nixinfra/certs/ca-chain.cert.pem
    export ETCDCTL_CERT=/home/nixinfra/certs/${etcdNode.name}-client-tls.cert.pem
    export ETCDCTL_KEY=/home/nixinfra/certs/${etcdNode.name}-client-tls.key.pem
    export ETCDCTL_API=3
    etcdctl --endpoints=https://${etcdNode.ipAddr}:2379 get --prefix /coreos.com/network/subnets
  ''', stdout: true, stderr: true);
```

**Rationale:**  
- etcdctl uses certificates from new location

---

### Change #25: lib/secrets.dart (Line 8)

**Location:** File comment

**Current Code:**
```dart
// systemd-creds encrypt - /root/secrets/[app-name].enc <<<"secret goes here"
```

**New Code:**
```dart
// systemd-creds encrypt - /home/nixinfra/secrets/[app-name].enc <<<"secret goes here"
```

**Rationale:**  
- Documentation update

---

### Change #26: lib/secrets.dart (Line 10, 12, 24)

**Location:** Comments

**Current Code:**
```dart
// 1. Make sure "/root/secrets" exists
// 2. Make sure "ca/secrets" exists
// 3. Create a new secret file with "systemd-creds encrypt - /root/secrets/[secret-namespaced].enc <<<"secret"
```

**New Code:**
```dart
// 1. Make sure "/home/nixinfra/secrets" exists
// 2. Make sure "ca/secrets" exists
// 3. Create a new secret file with "systemd-creds encrypt - /home/nixinfra/secrets/[secret-namespaced].enc <<<"secret"
```

**Rationale:**  
- Documentation update

---

### Change #27: lib/secrets.dart (Line 117)

**Location:** `deploySecretOnRemote()` function

**Current Code:**
```dart
await shell
    .run('$sshCmd "systemd-creds encrypt - /root/secrets/$secretName"');
```

**New Code:**
```dart
await shell
    .run('$sshCmd "systemd-creds encrypt - /home/nixinfra/secrets/$secretName"');
```

**Rationale:**  
- Secrets stored in new location

---

### Change #28: lib/helpers.dart (Line 62)

**Location:** Comment in substitute() function

**Current Code:**
```dart
// Secrets are deployed as encrypted files in /root/secrets of target node
```

**New Code:**
```dart
// Secrets are deployed as encrypted files in /home/nixinfra/secrets of target node
```

**Rationale:**  
- Documentation update

---

## Category 5: Comment/Documentation References

### Change #29: bin/commands/shared.dart

**Location:** Any references to `/root/uploads/`

**Pattern:**
```dart
// OLD: "/root/uploads/"
// NEW: "/home/nixinfra/uploads/"
```

**Action:** Search for `/root/uploads/` and replace with `/home/nixinfra/uploads/`

---

### Change #30: bin/commands/etcd.dart

**Location:** Any references to `/root/certs/`

**Pattern:**
```dart
// OLD: "/root/certs/"
// NEW: "/home/nixinfra/certs/"
```

**Action:** Search for `/root/certs/` and replace with `/home/nixinfra/certs/`

---

## Category 6: MCP Server Blacklist

### Change #31: bin/mcp_server/remote_command.dart (Line 82)

**Location:** Remote command validation

**Current Code:**
```dart
// Blacklist of commands that are never allowed
const deniedCommands = {
  'sudo',  // ← Remove this after gate script is deployed
  'su',
  'systemctl',  // ← This is read-only safe, could be allowed
  // ... other commands
};
```

**New Code (Phase 1: Before Gate Script):**
```dart
const deniedCommands = {
  'sudo',  // Still blacklisted - gate script not yet deployed
  'su',
  'systemctl',  // Restricted to read-only ops
  // ... other commands
};
```

**New Code (Phase 2: After Gate Script):**
```dart
const deniedCommands = {
  // 'sudo' removed - gate script is now deployed
  'su',
  // systemctl is read-only safe - can be allowed via MCP gate script
  // ... other commands
};

// MCP-specific commands allowed via gate script:
const mcp_allowed_commands = {
  'systemctl status',
  'systemctl show',
  'journalctl',
  'etcdctl get',
  'nix-store -q',
};
```

**Rationale:**  
- Phase 1: Maintain current security posture
- Phase 2: After gate script deployed, MCP can use gate for validation
- Read-only commands become safe

**Note:** This is a **phased change**. Initial migration keeps `sudo` blacklisted until gate script is verified in production.

---

## Summary Table: All Changes

| # | File | Line | Type | Change | Priority |
|----|------|------|------|--------|----------|
| 1 | lib/types.dart | 26 | Default | `'root'` → `'nixinfra'` | 🟢 P0 |
| 2 | lib/certificates.dart | 350 | SSH Client | `username: 'root'` → `username: node.username` | 🟢 P0 |
| 3 | lib/provision.dart | 139 | Path | `/root/install.sh` → `/home/nixinfra/install.sh` | 🟢 P0 |
| 4 | lib/provision.dart | 142 | Path | `/root/configuration.nix` → `/home/nixinfra/staging/configuration.nix` | 🟢 P0 |
| 5 | lib/provision.dart | 202 | Path | `/root/install.sh` → `/home/nixinfra/install.sh` | 🟢 P0 |
| 6 | lib/provision.dart | 225 | Shell SSH | `root@` → `${node.username}@` | 🟢 P0 |
| 7 | lib/provision.dart | 237 | Shell SSH | Keep as `root@` (bootstrap phase) | ⚪ No Change |
| 8 | lib/provision.dart | 298 | Shell SSH | `root@` → `${node.username}@` | 🟢 P0 |
| 9 | lib/docker_registry.dart | 33 | Shell SSH | `root@` → `${node.username}@` | 🟢 P0 |
| 10 | lib/docker_registry.dart | 82 | Shell SSH | `root@` → `${node.username}@` | 🟢 P0 |
| 11 | lib/secrets.dart | 103 | Shell SSH | `root@` → `${node.username}@` | 🟢 P0 |
| 12 | lib/ssh.dart | 146 | Path | `/root/action.sh` → `/home/nixinfra/action.sh` | 🟢 P0 |
| 13 | lib/ssh.dart | 151 | Path | `/root/action.sh` → `/home/nixinfra/action.sh` | 🟢 P0 |
| 14 | lib/ssh.dart | 155 | Path | `/root/action.sh` → `/home/nixinfra/action.sh` | 🟢 P0 |
| 15 | lib/ssh.dart | 136 | Debug | `/root/action.sh` → `/home/nixinfra/action.sh` | 🟡 P2 |
| 16 | lib/certificates.dart | 357 | Path | `/root/certs` → `/home/nixinfra/certs` | 🟢 P0 |
| 17 | lib/certificates.dart | 363 | Path | `/root/certs/` → `/home/nixinfra/certs/` | 🟢 P0 |
| 18 | lib/certificates.dart | 381-382 | Path | `/root/certs` → `/home/nixinfra/certs` | 🟢 P0 |
| 19 | lib/cluster_node.dart | 271-273 | Path | `/root/certs/` → `/home/nixinfra/certs/` | 🟢 P0 |
| 20 | lib/cluster_node.dart | 295-296 | Path | `/root/certs/` → `/home/nixinfra/certs/` | 🟢 P0 |
| 21 | lib/secrets.dart | 149 | Path | `/root/secrets` → `/home/nixinfra/secrets` | 🟢 P0 |
| 22 | lib/secrets.dart | 176 | Path | `/root/secrets` → `/home/nixinfra/secrets` | 🟢 P0 |
| 23 | lib/secrets.dart | 179-180 | Path | `/root/secrets/` → `/home/nixinfra/secrets/` | 🟢 P0 |
| 24 | lib/helpers.dart | 224-226 | Path | `/root/certs/` → `/home/nixinfra/certs/` | 🟢 P0 |
| 25 | lib/secrets.dart | 8 | Comment | Documentation | 🟡 P2 |
| 26 | lib/secrets.dart | 10,12,24 | Comment | Documentation | 🟡 P2 |
| 27 | lib/secrets.dart | 117 | Path | `/root/secrets/` → `/home/nixinfra/secrets/` | 🟢 P0 |
| 28 | lib/helpers.dart | 62 | Comment | Documentation | 🟡 P2 |
| 29 | bin/commands/shared.dart | TBD | Path | `/root/uploads/` → `/home/nixinfra/uploads/` | 🟢 P0 |
| 30 | bin/commands/etcd.dart | TBD | Path | `/root/certs/` → `/home/nixinfra/certs/` | 🟢 P0 |
| 31 | bin/mcp_server/remote_command.dart | 82 | Config | Phase 2: Remove 'sudo' from blacklist | 🟠 P1 |

**Total Changes:** 31 (27 code, 4 documentation)  
**Implementation Time:** 2-3 hours (mostly find-and-replace)

---

## Testing Strategy

### Unit Tests Required

1. **lib/types.dart:**
   ```dart
   test('ClusterNode defaults to nixinfra user', () {
     final node = ClusterNode('test', '10.0.0.1', 1, 'key');
     expect(node.username, 'nixinfra');
   });
   
   test('ClusterNode respects explicit username', () {
     final node = ClusterNode('test', '10.0.0.1', 1, 'key');
     node.username = 'root';  // Legacy
     expect(node.username, 'root');
   });
   ```

2. **lib/ssh.dart:**
   - Verify SFTP sends to `/home/nixinfra/action.sh`
   - Verify execution references new path

3. **lib/certificates.dart:**
   - Verify cert directory created at `/home/nixinfra/certs/`
   - Verify permissions set correctly

4. **lib/cluster_node.dart & helpers.dart:**
   - Verify etcdctl env vars use new cert paths

---

## Migration Checklist

- [ ] Update lib/types.dart line 26
- [ ] Update lib/certificates.dart line 350
- [ ] Update lib/provision.dart lines 139, 142, 202, 225, 298
- [ ] Update lib/docker_registry.dart lines 33, 82
- [ ] Update lib/secrets.dart lines 103, 117, 149, 176, 179-180
- [ ] Update lib/ssh.dart lines 136, 146, 151, 155
- [ ] Update lib/cluster_node.dart lines 271-273, 295-296
- [ ] Update lib/helpers.dart lines 62, 224-226
- [ ] Update bin/commands/shared.dart (search `/root/uploads/`)
- [ ] Update bin/commands/etcd.dart (search `/root/certs/`)
- [ ] Update comments/documentation throughout
- [ ] Run unit tests
- [ ] Test on single node
- [ ] Test on multi-node cluster
- [ ] Verify backward compatibility (root user still works)

---

## Rollback Strategy

If issues occur:

1. **Revert to root SSH:**
   ```dart
   // Quickly revert by changing:
   String username = 'nixinfra';  // → Change back to 'root'
   ```

2. **Environment Override:**
   ```bash
   NIX_INFRA_SSH_USER=root nix-infra deploy
   ```

3. **Per-Cluster Config:**
   ```yaml
   servers:
     - name: node1
       username: root  # Override per-node
   ```

All changes are backward-compatible through configuration.

---

## Conclusion

All code changes are **straightforward, localized, and low-risk**:
- Most changes are find-and-replace (paths)
- Only 2 changes modify logic (default username, SSH client initialization)
- All changes are backward-compatible
- Complete test coverage possible
- Rollback strategy is simple

The migration can be completed in a single code review and deployment cycle.
