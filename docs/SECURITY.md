# Security

This document describes nix-infra's security model, encryption mechanisms, trust boundaries, known limitations, and areas for improvement. It aims to be transparent and honest — understanding what is and isn't protected helps you make informed decisions about your infrastructure.

## Security Model Overview

nix-infra is an SSH-based configuration management tool. Like Ansible, Terraform with SSH provisioners, or NixOps, it assumes **root SSH access** to all managed nodes. The operator's workstation is the trust anchor — whoever has access to the project directory and the secrets password controls the infrastructure.

This means:

- The local project directory contains sensitive material (CA keys, encrypted secrets, SSH keys)
- The secrets password (`SECRETS_PWD`) unlocks all encrypted secrets
- All remote operations are performed as root over SSH
- There is no multi-user access control — a single operator (or CI pipeline) manages the fleet

This is appropriate for small-to-medium self-hosted infrastructure. If you need multi-tenant access control, audit logging, or role-based permissions, you'll need additional tooling on top of nix-infra.

## Transport Security

All communication between the operator's workstation and managed nodes uses SSH. There is no unencrypted management traffic.

**SSH connections** are established using the [dartssh2](https://pub.dev/packages/dartssh2) library, which supports RSA key authentication. All remote commands, file transfers (SFTP), and port forwarding use SSH tunnels.

**WireGuard** encrypts the overlay network between nodes. The Flanneld overlay network uses WireGuard tunnels, so inter-node traffic (including etcd replication and service mesh communication) is encrypted in transit even on shared networks.

**TLS** secures etcd communication. Both client-to-server and peer-to-peer etcd traffic use mutual TLS with certificates issued by the project's own certificate authority.

## Secrets at Rest

Secrets are stored locally in the `secrets/` directory, encrypted with OpenSSL pbkdf2:

```
openssl enc -pbkdf2 -pass env:SECRETS_PASS -a -out secrets/<name>
```

Key properties:

- Encryption uses PBKDF2 key derivation with a password you provide (`SECRETS_PWD`)
- Encrypted files are base64-encoded for safe storage and version control
- File permissions are set to mode `400` (owner read-only)
- The `secrets/` directory is set to mode `700`

The encryption key (`SECRETS_PWD`) is either typed interactively at each command invocation or set as an environment variable. See [Known Limitations](#known-limitations) for the implications of this.

## Secrets in Transit

When deploying secrets to nodes, the decrypted secret value is **piped via stdin** through an SSH tunnel. This is a deliberate design choice — secrets never appear in command-line arguments where they could be visible via `ps` on either the local or remote machine.

For regular secrets:
```
stdin → SSH tunnel → systemd-creds encrypt - /root/secrets/<name>
```

For pre-build secrets:
```
stdin → SSH tunnel → cat > /run/keys/<name>
```

## Secrets at Runtime

nix-infra uses two mechanisms for runtime secrets, depending on when the secret is needed:

### Standard Secrets — systemd-creds

Regular secrets are encrypted on the remote node using `systemd-creds encrypt`. This ties the encrypted secret to the specific machine's TPM or machine ID, so the encrypted file is only decryptable on that node.

Encrypted secrets are stored in `/root/secrets/` on each node.

**Current gap:** While `systemd-creds encrypt` is correctly implemented, the generated NixOS service configurations do not yet use `LoadCredentialEncrypted=` directives. This means services access secrets through other mechanisms rather than the full systemd credential pipeline. See `lib/analysis/SYSTEMD_CREDENTIALS_ANALYSIS.md` for the detailed analysis.

### Pre-build Secrets — tmpfs

Some secrets are needed at NixOS build time (before `nixos-rebuild switch` runs), such as container registry credentials for fetching private images. These are deployed decrypted to `/run/keys/` on a tmpfs filesystem:

- `/run/keys/` is a tmpfs mount (never written to persistent storage)
- File permissions are mode `0400` (root read-only)
- Directory permissions are mode `700`
- Available to the nix-daemon during builds

The NixOS configuration is updated to reference these paths so the build system can access them. See [Known Limitations](#known-limitations) for security implications.

## Certificate Authority (PKI)

nix-infra creates a local PKI for etcd TLS communication:

### Hierarchy

```
Root CA (4096-bit RSA, 20-year validity)
└── Intermediate CA (4096-bit RSA, 10-year validity)
    ├── TLS certificates (2048-bit RSA, 5-year validity)
    └── Peer certificates (2048-bit RSA, 5-year validity)
```

### Certificate Types

- **TLS certificates** — Used for etcd client-to-server communication. Each node gets its own certificate with `subjectAltName` set to the node's IP address and `127.0.0.1`.
- **Peer certificates** — Used for etcd cluster-to-cluster replication. Same per-node issuance with IP-based SANs.

### Key Protection

- Root CA key is AES-256 encrypted with a password (`CA_PASS`)
- Intermediate CA key is AES-256 encrypted with a separate password (`INTERMEDIATE_CA_PASS`)
- Private keys are stored with mode `400`
- The `private/` directories are mode `700`
- CA chain certificates are deployed to `/root/certs/` on cluster nodes with mode `400`

## Network Security

### Overlay Network

In cluster mode, nodes communicate over an encrypted overlay network:

- **Flanneld** manages IP allocation and routing between nodes
- **WireGuard** encrypts all overlay traffic
- Each node gets a subnet from the overlay address space
- Only the ingress layer (HAProxy on control nodes) is exposed on the public network

### Service Mesh

The service mesh (etcd + confd + HAProxy) runs entirely on the overlay network:

- etcd listens on overlay IPs, not public IPs
- HAProxy load balancers bind to overlay addresses
- confd watches etcd for service registration changes and reconfigures HAProxy

This means application services are not directly reachable from the internet — traffic must pass through the ingress layer.

## SSH Key Management

nix-infra generates RSA 2048-bit SSH key pairs for node authentication:

```
ssh-keygen -t rsa -b 2048 -C <email> -f ssh/<key-name>
```

Key details:

- Keys are stored in the project's `ssh/` directory
- RSA is used instead of Ed25519 due to dartssh2 library compatibility requirements (the dartssh library has limited support for newer key types and MAC algorithms)
- For Hetzner Cloud, public keys are registered with the cloud provider API
- For self-hosted servers, keys must be manually deployed
- `StrictHostKeyChecking=no` is used for SSH connections (nodes are frequently reprovisioned with new host keys)

## MCP Server Safety

nix-infra includes experimental MCP (Model Context Protocol) servers for AI-assisted infrastructure management. These have deliberate safety restrictions:

### Command Filtering

Remote command execution uses a dual-layer filtering system:

**Blacklist** (always blocked, overrides whitelist):
`rm`, `chown`, `chmod`, `dd`, `shred`, `wipe`, `kill`, `killall`, `pkill`, `shutdown`, `reboot`, `halt`, `init`, `passwd`, `su`, `sudo`, `eval`, `exec`, `rsync`, `ssh`, `curl`, `wget`

**Whitelist** (allowed commands):
System info (`uname`, `uptime`, `who`), process monitoring (`ps`, `top`, `htop`), resource monitoring (`free`, `df`, `du`, `iostat`), network diagnostics (`ip`, `ss`, `ping`, `traceroute`, `dig`), service management (`systemctl`, `journalctl`), file inspection (`ls`, `find`, `stat`, `cat`), and hardware info (`lscpu`, `lsmem`, `sensors`).

Commands must appear on the whitelist and not on the blacklist. Any unrecognized command is rejected.

### Known MCP Limitations

- The `systemctl` whitelist entry needs further sub-command restrictions (e.g., `systemctl stop` should likely be blocked)
- Command parsing handles basic pipes and chains but may not catch all shell injection patterns
- The MCP servers are experimental and should not be considered production-hardened

## Known Limitations

Being transparent about limitations helps you make informed security decisions:

### No SELinux Support
NixOS does not officially support SELinux. Mandatory access control is not available to restrict what processes can do beyond standard Unix permissions.

### No AppArmor Hardening (Yet)
AppArmor profiles for services are not yet implemented. This is a planned improvement that would restrict what each service can access on the filesystem and network.

### Root SSH Access
All management operations run as root. This is standard for configuration management tools but means a compromised operator workstation has full access to all nodes. A defense-in-depth analysis was performed — see `lib/analysis/ARCHITECTURE_DEFENSE_IN_DEPTH_SSH.md`.

### No Config Folder Encryption at Rest
The project directory (containing CA keys, encrypted secrets, SSH keys) is not encrypted at rest. It relies on the operator's filesystem-level encryption (e.g., FileVault, LUKS). If the project directory is committed to a git repository, ensure the repository is private and access-controlled.

### No Secret Rotation
There is no built-in mechanism for rotating secrets. To rotate a secret, you must re-encrypt it with `nix-infra store-secret` and redeploy. Certificate rotation requires regenerating certificates and redeploying them to nodes.

### No Virtual TPM on Hetzner Cloud
Hetzner Cloud does not provide virtual TPM, so `systemd-creds encrypt` falls back to machine-ID-based encryption rather than hardware-backed encryption. This means the encrypted secrets on a node are only as secure as the machine ID.

### SECRETS_PWD Exposure Risk
The secrets password is either typed interactively or set as an environment variable. If set as an environment variable, it may appear in shell history, process listings, or CI logs. Use care with how you provide this value.

### Pre-build Secrets Accessibility
Pre-build secrets are deployed decrypted to `/run/keys/` (tmpfs). While this avoids writing them to persistent storage, any root process on the node can read them while they exist. They are necessary for the NixOS build process but represent a wider exposure window than systemd-creds encrypted secrets.

### dartssh Library Constraints
The dartssh2 Dart library limits SSH algorithm choices. RSA 2048-bit keys are used instead of Ed25519, and some MAC algorithms may not be available. This is a trade-off of using a pure-Dart SSH implementation.

### StrictHostKeyChecking Disabled
SSH connections use `StrictHostKeyChecking=no` because nodes are frequently reprovisioned and get new host keys. This means nix-infra does not verify the host key on connection, which in theory allows MITM attacks on the management channel. In practice, this is mitigated by operating on known IP addresses from trusted networks.

## Room for Improvement

The following improvements are planned or under consideration:

- **AppArmor profiles** — Restrict service capabilities with mandatory access control
- **Config folder encryption** — Encrypt the project directory at rest, independent of OS-level encryption
- **Secret rotation** — Automated rotation for secrets and certificates with zero-downtime redeployment
- **Virtual TPM support** — Use hardware-backed encryption when providers support it
- **LoadCredentialEncrypted integration** — Complete the systemd credential pipeline so services use `LoadCredentialEncrypted=` directives
- **MCP sub-command restrictions** — Tighten the whitelist for commands like `systemctl` that have dangerous sub-commands
- **Ed25519 key support** — Migrate to Ed25519 keys when dartssh2 support matures

## Operational Security Recommendations

### Protect the Project Directory
The project directory is the trust anchor. It contains SSH keys, CA keys, and encrypted secrets. Treat it with the same care as you would production credentials:

- Use full-disk encryption on the operator workstation
- If stored in git, use a private repository with strict access controls
- Consider encrypting the directory with an additional layer (e.g., `git-crypt`)
- Back up the `ca/` directory separately — losing it means regenerating all certificates

### Handle SECRETS_PWD Carefully
- Prefer typing the password interactively over setting it as an environment variable
- If using environment variables in CI, use the CI system's secret management (e.g., GitHub Actions secrets)
- Avoid storing it in `.env` files that might be committed to version control
- Add `.env` to `.gitignore`

### SSH Key Hygiene
- Generate separate SSH key pairs for separate environments (production, staging)
- Store SSH keys only in the project's `ssh/` directory
- Never reuse SSH keys across unrelated projects

### Monitoring
- Monitor SSH login attempts on managed nodes via `journalctl -u sshd`
- Set up alerts for unexpected configuration changes
- Regularly review `systemctl` service status on nodes

### Backup
- Back up the `ca/` directory — it contains your certificate authority
- Back up the `secrets/` directory — it contains your encrypted secrets
- Test restoring from backup periodically
- The `SECRETS_PWD` must be stored separately from the backup (e.g., in a password manager)
