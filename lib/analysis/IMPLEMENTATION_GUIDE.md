# Defense-in-Depth SSH Implementation Guide

**Document Version:** 1.0  
**Status:** Complete Implementation Guide  
**Last Updated:** 2026-02-09

---

## Overview

This guide provides a complete roadmap for implementing the defense-in-depth SSH architecture for nix-infra. It consolidates the architectural design and code changes into a step-by-step implementation plan with verification procedures.

**Related Documents:**
- `ARCHITECTURE_DEFENSE_IN_DEPTH_SSH.md` — Detailed architecture and design
- `CODE_CHANGES_MIGRATION_PLAN.md` — Specific code changes with line numbers

---

## Table of Contents

1. [Implementation Phases](#implementation-phases)
2. [Layer 1: Non-Root User Setup](#layer-1-non-root-user-setup)
3. [Layer 2: Sudo Whitelist](#layer-2-sudo-whitelist)
4. [Layer 3: SSH Gate Script](#layer-3-ssh-gate-script)
5. [Code Migration](#code-migration)
6. [NixOS Configuration](#nixos-configuration)
7. [Testing & Verification](#testing--verification)
8. [Rollout Checklist](#rollout-checklist)

---

## Implementation Phases

### Phase 1: Foundation (Week 1-2)
- [ ] Create NixOS configuration module with nixinfra user
- [ ] Design and test SSH gate script
- [ ] Verify SFTP+exec compatibility with dartssh2
- [ ] Deploy to single test node

### Phase 2: Code Migration (Week 2-3)
- [ ] Update ClusterNode.username default
- [ ] Migrate all /root/ paths to /home/nixinfra/
- [ ] Update shell SSH commands to use node.username
- [ ] Run unit tests

### Phase 3: Integration & Testing (Week 3-4)
- [ ] Deploy to multi-node test cluster
- [ ] Verify all operations work with gate script
- [ ] Test backward compatibility (root user)
- [ ] Performance testing

### Phase 4: Rollout (Week 4-5)
- [ ] Announce to users
- [ ] Update documentation
- [ ] Set new deployments to use nixinfra user
- [ ] Provide migration guide for existing nodes

---

## Layer 1: Non-Root User Setup

### 1.1 Create nixinfra User

The nixinfra user must be created as a normal (non-system) user with home directory.

**NixOS Configuration:**

```nix
users.users.nixinfra = {
  isNormalUser = true;
  home = "/home/nixinfra";
  description = "nix-infra automation user";
  shell = pkgs.bash;
  uid = 1000;  # Or auto-assign
  # No password - SSH key auth only
  passwordFile = null;
};
```

**Verification Commands:**

```bash
# Verify user exists
id nixinfra
# Expected output: uid=1000(nixinfra) gid=100(users) groups=100(users)

# Verify home directory
ls -la /home/nixinfra/
# Expected: drwxr-xr-x nixinfra:nixinfra /home/nixinfra/

# Verify no password
getent shadow nixinfra | cut -d: -f2
# Expected output: ! (locked)
```

### 1.2 Create Home Directory Structure

The provisioning process must ensure all required directories exist.

**Directory Structure:**

```
/home/nixinfra/
├── certs/          (700, nixinfra:nixinfra)
├── secrets/        (700, nixinfra:nixinfra)
├── staging/        (700, nixinfra:nixinfra)
├── uploads/        (700, nixinfra:nixinfra)
└── .ssh/           (700, nixinfra:nixinfra)
```

**NixOS Configuration:**

```nix
system.activationScripts.nixinfraSetup = ''
  mkdir -p /home/nixinfra/{certs,secrets,staging,uploads,.ssh}
  chown -R nixinfra:nixinfra /home/nixinfra
  chmod 700 /home/nixinfra
  chmod 700 /home/nixinfra/{certs,secrets,staging,uploads,.ssh}
'';
```

### 1.3 Blast Radius Limitation

**Verify that nixinfra user cannot:**
- Modify /etc/nixos/ files (permission denied)
- Modify /etc/ssh/ files (permission denied)
- Read other users' files (permission denied)
- Install system packages (permission denied)
- Change system time (permission denied)

**Verification:**

```bash
# As nixinfra user, try to modify /etc/nixos/configuration.nix
sudo su -s /bin/bash nixinfra
ls -la /etc/nixos/configuration.nix
# Expected: -rw-r--r-- root:root (not writable by nixinfra)

touch /etc/nixos/test.txt
# Expected: Permission denied
```

---

## Layer 2: Sudo Whitelist

### 2.1 Configure Sudoers

The sudoers file must whitelist only specific commands with specific arguments.

**sudoers Syntax:**

```bash
# /etc/sudoers (via NixOS)
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild switch --fast
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild boot --fast
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nix-collect-garbage -d
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nix-channel --add *
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/systemctl restart flannel
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/systemctl restart confd
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/systemctl restart kubelet
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/systemctl restart etcd
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/cp /home/nixinfra/staging/* /etc/nixos/*
nixinfra ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/mkdir -p /etc/nixos/*
```

**NixOS Configuration:**

```nix
security.sudo = {
  enable = true;
  extraRules = [
    {
      users = [ "nixinfra" ];
      commands = [
        {
          command = "${pkgs.nixos-tools}/bin/nixos-rebuild";
          options = [ "NOPASSWD" "SETENV" ];
        }
        # ... more commands
      ];
    }
  ];
};
```

### 2.2 Verify Sudo Rules

**Verification:**

```bash
# Check what nixinfra can run with sudo
sudo -U nixinfra -l
# Expected: list of allowed commands

# Try a denied command as nixinfra
sudo -U nixinfra /bin/rm -rf /
# Expected: sudo: command not allowed

# Try an allowed command as nixinfra
sudo -U nixinfra nixos-rebuild switch --fast
# Expected: command executes
```

---

## Layer 3: SSH Gate Script

### 3.1 Gate Script Placement & Permissions

**Location:** `/etc/nixinfra/gate.sh`  
**Owner:** `root:root`  
**Permissions:** `755` (rwxr-xr-x)  
**Purpose:** Validate and route all SSH exec/SFTP channels

### 3.2 Gate Script Implementation

**Complete Implementation:**

```bash
#!/bin/bash
set -e

# /etc/nixinfra/gate.sh
# Defense-in-depth gate script for nix-infra operations SSH key
# Validates commands against whitelist and routes SFTP

# Logging function
log_command() {
    logger -t nixinfra-gate -p auth.info "user=$1 command=$2 result=$3"
}

# Detect if this is an SFTP subsystem channel
if [ -z "$SSH_ORIGINAL_COMMAND" ]; then
    # SFTP subsystem - SSH_ORIGINAL_COMMAND is empty when restrict is used
    log_command "$LOGNAME" "sftp-server" "start"
    exec /usr/lib/openssh/sftp-server
    exit 0
fi

# Exec channel - validate against whitelist
case "$SSH_ORIGINAL_COMMAND" in
    # Rebuild configurations
    "nixos-rebuild switch --fast")
        log_command "$LOGNAME" "nixos-rebuild switch --fast" "allow"
        exec sudo /run/current-system/sw/bin/nixos-rebuild switch --fast
        ;;
    "nixos-rebuild boot --fast")
        log_command "$LOGNAME" "nixos-rebuild boot --fast" "allow"
        exec sudo /run/current-system/sw/bin/nixos-rebuild boot --fast
        ;;
    
    # Garbage collection
    "nix-collect-garbage -d")
        log_command "$LOGNAME" "nix-collect-garbage -d" "allow"
        exec sudo /run/current-system/sw/bin/nix-collect-garbage -d
        ;;
    
    # Channel management
    "nix-channel --add "*)
        log_command "$LOGNAME" "nix-channel --add" "allow"
        exec sudo /run/current-system/sw/bin/nix-channel --add ${SSH_ORIGINAL_COMMAND#nix-channel }
        ;;
    
    # Service management
    "systemctl restart "*)
        local service="${SSH_ORIGINAL_COMMAND#systemctl restart }"
        case "$service" in
            flannel|confd|kubelet|etcd)
                log_command "$LOGNAME" "systemctl restart $service" "allow"
                exec sudo /run/current-system/sw/bin/systemctl restart "$service"
                ;;
            *)
                log_command "$LOGNAME" "systemctl restart $service" "deny"
                echo "Denied: systemctl restart $service" >&2
                exit 1
                ;;
        esac
        ;;
    
    # Systemd secrets encryption
    "systemd-creds encrypt "*)
        log_command "$LOGNAME" "systemd-creds encrypt" "allow"
        exec sudo /run/current-system/sw/bin/systemd-creds encrypt ${SSH_ORIGINAL_COMMAND#systemd-creds encrypt }
        ;;
    
    # File operations (staging → system)
    "cp /home/nixinfra/staging/"*)
        if [[ "$SSH_ORIGINAL_COMMAND" =~ ^cp\ /home/nixinfra/staging/[^/\ ]+\ /etc/nixos/[^/\ ]+$ ]]; then
            log_command "$LOGNAME" "cp staging to system" "allow"
            exec sudo /run/current-system/sw/bin/cp ${SSH_ORIGINAL_COMMAND#cp }
        else
            log_command "$LOGNAME" "cp staging to system" "deny"
            echo "Denied: Invalid cp pattern" >&2
            exit 1
        fi
        ;;
    
    # Directory creation
    "mkdir -p /etc/nixos/"*)
        log_command "$LOGNAME" "mkdir /etc/nixos/" "allow"
        exec sudo /run/current-system/sw/bin/mkdir -p ${SSH_ORIGINAL_COMMAND#mkdir -p }
        ;;
    
    # Anything else is denied
    *)
        log_command "$LOGNAME" "unknown" "deny"
        echo "Command denied: $SSH_ORIGINAL_COMMAND" >&2
        exit 1
        ;;
esac

# Should not reach here
exit 1
```

**NixOS Configuration:**

```nix
# Create gate script
environment.etc."nixinfra/gate.sh" = {
  mode = "0755";
  user = "root";
  group = "root";
  text = ''
    #!/bin/bash
    set -e
    
    log_command() {
      logger -t nixinfra-gate -p auth.info "user=$1 command=$2 result=$3"
    }
    
    if [ -z "$SSH_ORIGINAL_COMMAND" ]; then
      log_command "$LOGNAME" "sftp-server" "start"
      exec ${pkgs.openssh}/libexec/sftp-server
      exit 0
    fi
    
    case "$SSH_ORIGINAL_COMMAND" in
      # ... all cases from above
    esac
    
    exit 1
  '';
};
```

### 3.3 SSH Key Configuration

**Operations Key** (used by nix-infra CLI):

```
restrict,command="/etc/nixinfra/gate.sh" ssh-rsa AAAA...KeyContent...== ops@nix-infra
```

**Interactive Key** (used by `nix-infra ssh` for sysops):

```
ssh-rsa AAAA...KeyContent...== sysops@nix-infra
```

**NixOS Configuration:**

```nix
users.users.nixinfra = {
  isNormalUser = true;
  home = "/home/nixinfra";
  description = "nix-infra automation user";
  shell = pkgs.bash;
  openssh.authorizedKeys.keys = [
    # Operations key
    "restrict,command=\"/etc/nixinfra/gate.sh\" ssh-rsa AAAA...ops-key... ops@nix-infra"
    
    # Interactive key
    "ssh-rsa AAAA...interactive-key... sysops@nix-infra"
  ];
};
```

### 3.4 Verify Gate Script

**Test SFTP Channel:**

```bash
# As nixinfra user, verify SFTP works
echo "test content" > /tmp/test.txt
sftp -i /path/to/ops/key nixinfra@target-node
> put /tmp/test.txt /home/nixinfra/certs/test.txt
# Expected: file upload succeeds

# List files
> ls /home/nixinfra/certs/
# Expected: test.txt listed
```

**Test Exec Channel:**

```bash
# As operations SSH key, try an allowed command
ssh -i /path/to/ops/key nixinfra@target-node "nixos-rebuild switch --fast"
# Expected: command executes successfully

# Try a denied command
ssh -i /path/to/ops/key nixinfra@target-node "/bin/bash"
# Expected: connection closed (bash denied by gate script)

# Try to get interactive shell
ssh -i /path/to/ops/key nixinfra@target-node
# Expected: connection closed (no shell allowed)
```

### 3.5 Audit Trail Verification

**Check logs:**

```bash
sudo journalctl -u sshd
# Expected: log entries from gate script
# 2026-02-09 14:23:45 nixinfra-gate[12345]: user=nixinfra command="nixos-rebuild switch --fast" result=allow

sudo grep nixinfra-gate /var/log/auth.log
# Or check syslog depending on system
```

---

## Code Migration

### Step 1: Update Default Username

**File:** lib/types.dart, Line 26

```dart
// Before
String username = 'root';

// After
String username = 'nixinfra';
```

### Step 2: Update Hardcoded Usernames

**File:** lib/certificates.dart, Line 350

```dart
// Before
final sshClient = SSHClient(
  await SSHSocket.connect(node.ipAddr, 22),
  username: 'root',
  // ...
);

// After
final sshClient = SSHClient(
  await SSHSocket.connect(node.ipAddr, 22),
  username: node.username,
  // ...
);
```

### Step 3: Update Shell SSH Commands

**Pattern:** `root@${node.ipAddr}` → `${node.username}@${node.ipAddr}`

**Files to Update:**
- lib/provision.dart (lines 225, 298)
- lib/docker_registry.dart (lines 33, 82)
- lib/secrets.dart (line 103)

**Example:**

```dart
// Before
'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no root@${node.ipAddr} "command"'

// After
'ssh -i ${workingDir.path}/ssh/${node.sshKeyName} -o StrictHostKeyChecking=no ${node.username}@${node.ipAddr} "command"'
```

### Step 4: Update /root/ Paths

**Pattern:** `/root/` → `/home/nixinfra/` (or `/home/nixinfra/staging/` for /etc/nixos/ files)

**Path Mapping:**
- `/root/certs/` → `/home/nixinfra/certs/`
- `/root/secrets/` → `/home/nixinfra/secrets/`
- `/root/action.sh` → `/home/nixinfra/action.sh`
- `/root/uploads/` → `/home/nixinfra/uploads/`
- `/root/configuration.nix` → `/home/nixinfra/staging/configuration.nix`
- `/root/install.sh` → `/home/nixinfra/install.sh`

**Files to Update:**
- lib/ssh.dart (lines 136, 146, 151, 155)
- lib/certificates.dart (lines 357, 363, 381-382)
- lib/cluster_node.dart (lines 271-273, 295-296)
- lib/helpers.dart (lines 62, 224-226)
- lib/secrets.dart (lines 8, 10, 12, 24, 117, 149, 176, 179-180)
- bin/commands/shared.dart (search `/root/uploads/`)
- bin/commands/etcd.dart (search `/root/certs/`)

---

## NixOS Configuration

### Complete Configuration Module

Create a new NixOS module or add to existing configuration:

```nix
# configuration.nix or separate module
{ config, pkgs, ... }:

{
  # Create the nixinfra user
  users.users.nixinfra = {
    isNormalUser = true;
    home = "/home/nixinfra";
    description = "nix-infra automation user";
    shell = pkgs.bash;
    uid = 1000;
    openssh.authorizedKeys.keys = [
      # Operations key: restricted to gate script and SFTP
      "restrict,command=\"/etc/nixinfra/gate.sh\" ssh-rsa AAAA...ops-key... ops@nix-infra"
      
      # Interactive key: normal shell with sudo whitelist
      "ssh-rsa AAAA...interactive-key... sysops@nix-infra"
    ];
  };

  # Create home directories
  system.activationScripts.nixinfraSetup = ''
    mkdir -p /home/nixinfra/{certs,secrets,staging,uploads,.ssh}
    mkdir -p /etc/nixinfra
    chown -R nixinfra:nixinfra /home/nixinfra
    chmod 700 /home/nixinfra
    chmod 700 /home/nixinfra/{certs,secrets,staging,uploads,.ssh}
  '';

  # Install gate script
  environment.etc."nixinfra/gate.sh" = {
    mode = "0755";
    user = "root";
    group = "root";
    text = ''
      #!/bin/bash
      # [Gate script content from section 3.2]
    '';
  };

  # Configure sudo whitelist
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
    extraRules = [
      {
        users = [ "nixinfra" ];
        commands = [
          {
            command = "${pkgs.nixos-rebuild}/bin/nixos-rebuild";
            options = [ "NOPASSWD" "SETENV" ];
          }
          {
            command = "${pkgs.nix}/bin/nix-collect-garbage";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.nix}/bin/nix-channel";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.systemd}/bin/systemctl";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.coreutils}/bin/cp";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.coreutils}/bin/mkdir";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.coreutils}/bin/chmod";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };

  # SSH daemon configuration
  services.openssh = {
    enable = true;
    permitRootLogin = "no";
    passwordAuthentication = false;
    pubkeyAuthentication = true;
  };
}
```

---

## Testing & Verification

### Test 1: Single Node Bootstrap

**Procedure:**
1. Provision a single test node with new NixOS configuration
2. Wait for NixOS to boot
3. Verify nixinfra user exists
4. Verify SSH keys are installed

**Verification:**

```bash
# SSH as nixinfra with operations key
ssh -i /path/to/ops/key nixinfra@test-node "whoami"
# Expected output: nixinfra

# Try to get shell (should fail)
ssh -i /path/to/ops/key nixinfra@test-node
# Expected: connection closed

# SFTP should work
sftp -i /path/to/ops/key nixinfra@test-node <<EOF
cd /home/nixinfra/certs
put /tmp/test.txt
ls
EOF
# Expected: file transferred and listed
```

### Test 2: Single Node Deployment

**Procedure:**
1. Deploy configuration.nix via nixinfra CLI
2. Deploy certificates via SFTP
3. Run action scripts
4. Rebuild NixOS

**Verification:**

```bash
# Deploy configuration
nix-infra deploy --nodes test-node --wait

# Verify configuration deployed
ssh -i /path/to/ops/key nixinfra@test-node "cat /etc/nixos/configuration.nix | head"
# Expected: configuration content displayed

# Verify certs deployed
ssh -i /path/to/ops/key nixinfra@test-node "ls -la /home/nixinfra/certs/"
# Expected: certificate files listed with nixinfra:nixinfra ownership
```

### Test 3: Multi-Node Cluster

**Procedure:**
1. Deploy 3-node test cluster
2. Run full cluster operations
3. Verify inter-node communication

**Verification:**

```bash
# Deploy to all nodes
nix-infra deploy --all --wait

# Verify cluster health
nix-infra status
# Expected: all nodes healthy, operating as nixinfra user

# Test service restart
nix-infra restart-service flannel
# Expected: service restarted on all nodes
```

### Test 4: Backward Compatibility

**Procedure:**
1. Configure legacy node with `username: root` in servers.yaml
2. Attempt to deploy to both nixinfra and root nodes

**Verification:**

```yaml
# servers.yaml
servers:
  - name: test-nixinfra
    ip: 10.0.0.1
    # defaults to 'nixinfra'
  
  - name: test-root
    ip: 10.0.0.2
    username: root  # Legacy
```

```bash
# Deploy to both
nix-infra deploy --all
# Expected: both nodes deploy successfully, using their configured usernames
```

### Test 5: Gate Script Security

**Procedure:**
1. Attempt to execute denied commands
2. Verify audit trail

**Verification:**

```bash
# Try to get shell (should fail)
ssh -i /path/to/ops/key nixinfra@test-node
# Expected: command denied, connection closed

# Try to run rm (should fail)
ssh -i /path/to/ops/key nixinfra@test-node "rm -rf /tmp/test"
# Expected: command denied

# Try allowed command (should succeed)
ssh -i /path/to/ops/key nixinfra@test-node "nix-collect-garbage -d"
# Expected: command executes

# Check audit log
ssh -i /path/to/interactive/key nixinfra@test-node \
  "journalctl -u sshd | grep nixinfra-gate | tail"
# Expected: log entries showing command validations
```

---

## Rollout Checklist

### Pre-Rollout

- [ ] All documentation complete and reviewed
- [ ] Code changes implemented and tested
- [ ] NixOS configuration tested on test cluster
- [ ] Gate script tested and verified
- [ ] Backward compatibility verified
- [ ] Performance testing completed (no regressions)
- [ ] Security audit completed
- [ ] Rollback procedure documented and tested

### Rollout

- [ ] Announce change to users
- [ ] Update nix-infra documentation
- [ ] Set new default: username = 'nixinfra'
- [ ] Publish new version of nix-infra
- [ ] Provide migration guide for existing nodes
- [ ] Monitor for issues on new deployments
- [ ] Collect feedback from users

### Post-Rollout (Optional Migration)

- [ ] Send migration guide to existing users
- [ ] Provide one-click migration script (if applicable)
- [ ] Schedule sunset date for root user support (e.g., 6 months)
- [ ] Update security documentation
- [ ] Archive root user support information

---

## Troubleshooting

### Symptom: "Permission denied" when deploying certificates

**Cause:** Certs directory doesn't exist or has wrong permissions

**Solution:**
```bash
# On target node
ssh nixinfra@target-node
mkdir -p /home/nixinfra/certs
chmod 700 /home/nixinfra/certs
```

### Symptom: Gate script not running commands

**Cause:** Path to sudo is incorrect, or command pattern doesn't match

**Solution:**
1. Check gate script path in authorized_keys
2. Verify command syntax matches case statement exactly
3. Check sudo configuration
```bash
sudo -l -U nixinfra
```

### Symptom: SFTP fails, but exec works

**Cause:** SSH_ORIGINAL_COMMAND detection not working

**Solution:**
```bash
# Enable SSH logging
ssh -vvv -i key nixinfra@host
# Look for SSH_ORIGINAL_COMMAND in output
```

### Symptom: Slow SFTP transfers

**Cause:** Gate script logging is too verbose

**Solution:** Reduce logging frequency or send to separate log file

---

## Security Considerations

### Principle: Defense in Depth

The three-layer model means:
- **Layer 1 fails:** User can still do limited damage (non-root only)
- **Layer 2 fails:** User can only run whitelisted commands (gate script validates)
- **Layer 3 fails:** Unlikely (SSH transport level validation)

### Attack Scenarios

| Attack | Root User | Layer 1 | Layers 1+2 | All 3 |
|--------|-----------|---------|-----------|-------|
| Compromised SSH key → get shell | ✅ Pwned | ✅ Pwned | ✅ Limited | ❌ Denied |
| Compromised SSH key → reboot | ✅ Pwned | ✅ Pwned | ✅ Limited | ❌ Denied |
| Compromised SSH key → modify /etc/nixos/ | ✅ Pwned | ✅ Denied | ✅ Denied | ❌ Denied |
| Shell access → escalate to root | ✅ Pwned | ⚠️ Sudo whitelist | ✅ Denied | ✅ Denied |
| Supply chain attack on nix-infra | ✅ Pwned | ✅ Limited | ✅ Limited | ✅ Limited |

---

## Conclusion

This implementation guide provides everything needed to:

1. Design the defense-in-depth architecture
2. Implement all three security layers
3. Migrate existing code
4. Test and verify the implementation
5. Roll out to users
6. Troubleshoot issues

The migration is **non-breaking** (backward compatible) and **low-risk** (localized changes with good test coverage).

**Success Criteria:**
- ✅ All new nodes use nixinfra user by default
- ✅ All operations work with gate script validation
- ✅ All operations logged for audit trail
- ✅ Backward compatibility maintained (root user still works if explicitly configured)
- ✅ Zero downtime during migration
- ✅ Performance unchanged (or improved)
