# Infrastructure Providers

nix-infra supports multiple infrastructure providers through a pluggable abstraction layer. Providers are auto-detected based on your project configuration, so the same CLI commands work regardless of where your servers run.

## Provider Auto-Detection

When you run any nix-infra command, the provider is selected automatically:

1. If `servers.yaml` exists in your working directory → **Self-Hosting** provider
2. If `HCLOUD_TOKEN` is set in `.env` or environment → **Hetzner Cloud** provider
3. If neither is configured → error with instructions

If `servers.yaml` exists, it always takes precedence — even if `HCLOUD_TOKEN` is also set. This allows hybrid setups where some servers in `servers.yaml` delegate to Hetzner Cloud for dynamic IP resolution.

## Hetzner Cloud

The default cloud provider creates and manages servers on [Hetzner Cloud](https://www.hetzner.com/cloud).

### Setup

Add your Hetzner Cloud API token to the `.env` file in your project:

```sh
HCLOUD_TOKEN=your-hetzner-api-token
```

### Capabilities

| Feature | Supported |
|---------|:---------:|
| Create servers | ✓ |
| Destroy servers | ✓ |
| Placement groups | ✓ |
| SSH key management | ✓ |

### How It Works

When provisioning via Hetzner Cloud:

1. **Server creation** — New servers are created with Ubuntu 22.04 as the bootstrap OS via the Hetzner API
2. **SSH key registration** — Your SSH public key is automatically registered with Hetzner Cloud
3. **Placement groups** — For HA clusters, servers can be placed in spread placement groups to ensure they run on different physical hosts
4. **NixOS conversion** — After the Ubuntu server is ready, nixos-infect converts it to NixOS

### Provisioning Example

```sh
nix-infra cluster provision \
  --node-names="worker001 worker002" \
  --machine-type=cx22 \
  --location=fsn1 \
  --nixos-version=24.11 \
  --placement-group=my-cluster
```

## Self-Hosted Servers

For existing servers, bare metal machines, or other cloud providers, use the self-hosting provider by creating a `servers.yaml` file in your project root.

### servers.yaml Format

```yaml
servers:
  web-server-1:
    ip: 192.168.1.10
    ssh_key: ./ssh/web-server-key
    description: Primary web server       # Optional
    username: admin                        # Optional, defaults to 'root'
    metadata:                              # Optional, for your own use
      location: rack-1
      environment: production

  db-server-1:
    ip: 192.168.1.20
    ssh_key: /absolute/path/to/db-key
    description: Primary database server

  worker-1:
    ip: 10.0.0.5
    ssh_key: ./ssh/worker-key
```

### Field Reference

| Field | Required | Description |
|-------|:--------:|-------------|
| `ip` | Yes* | Server IP address. Required unless `provider` is set. |
| `ssh_key` | Yes | Path to SSH private key (relative to working directory or absolute) |
| `description` | No | Human-readable server description |
| `username` | No | SSH username (defaults to `root`) |
| `metadata` | No | Key-value pairs for your own organisation |
| `provider` | No* | Cloud provider name for dynamic IP resolution (e.g., `hetzner`). Mutually exclusive with `ip`. |

*Each server must have either `ip` or `provider`, but not both.

### Validation Rules

- Every server entry must have `ssh_key`
- Every server entry must have exactly one of `ip` or `provider`
- If `provider` is specified, the corresponding credentials must be available (e.g., `HCLOUD_TOKEN` for `hetzner`)

### Capabilities

| Feature | Supported |
|---------|:---------:|
| Create servers | ✗ |
| Destroy servers | ✗ |
| Placement groups | ✗ |
| SSH key management | ✗ (managed manually) |

The `provision` command still works with self-hosted servers — it converts the existing OS to NixOS via nixos-infect. You just can't create or destroy servers through nix-infra.

## Hybrid Mode

You can mix self-hosted servers with cloud-managed servers in the same `servers.yaml`. Servers with a `provider` field get their IP address resolved dynamically from the cloud provider API at runtime.

### Example: Static + Cloud-Managed

```yaml
servers:
  # Self-hosted server with static IP
  db-server-1:
    ip: 192.168.1.20
    ssh_key: ./ssh/db-key
    description: On-premise database server

  # Cloud-managed server — IP resolved from Hetzner API
  web-server-1:
    provider: hetzner
    ssh_key: ./ssh/cloud-key
    description: Hetzner Cloud web server

  # Another cloud-managed server
  worker-1:
    provider: hetzner
    ssh_key: ./ssh/cloud-key
    description: Hetzner Cloud worker
```

When using hybrid mode, you also need the cloud provider credentials in your `.env`:

```sh
HCLOUD_TOKEN=your-hetzner-api-token
```

The cloud-managed servers must already exist in Hetzner Cloud — the self-hosting provider does not create them. This mode is useful when you want to manage a mix of on-premise and cloud servers from a single configuration, or when migrating between providers.

## VMware Provisioning

For VMware environments, nix-infra supports a mutation system that customises the nixos-infect process. Mutations are alternative install scripts hosted in the [nixos-infect repository](https://github.com/jhsware/nixos-infect/tree/ki-dev/mutations).

### Usage

Pass the `--mutation` flag during provisioning:

```sh
nix-infra fleet provision \
  --node-names="vmware-server-1" \
  --nixos-version=24.11 \
  --mutation=nixos-infect-vmware
```

### How Mutations Work

During normal provisioning, `installNixos()` downloads and executes the standard nixos-infect script. When `--mutation` is specified, it instead downloads the mutation script from `https://raw.githubusercontent.com/jhsware/nixos-infect/refs/heads/ki-dev/mutations/<mutation-name>`.

The mutation script is applied with the `--apply` flag, which modifies the nixos-infect behavior for the target environment (e.g., VMware-specific disk layout, drivers, or boot configuration).

**Important:** When using mutations, the provisioning command returns early after the install script completes. You must manually reboot the server to complete the NixOS conversion. This is because custom environments may require manual verification before rebooting.

## Supported Base Images

The self-hosting provider works with servers running any of these distributions. nixos-infect converts them to NixOS during provisioning:

| Base Image | Verified System | Provisioning Time | Status |
|------------|----------------|-------------------|:------:|
| ubuntu-22.04 | Ubuntu 22.04.5 LTS | 2m 37s | ✓ |
| ubuntu-24.04 | Ubuntu 24.04.3 LTS | 2m 22s | ✓ |
| debian-11 | Debian GNU/Linux 11 (bullseye) | 2m 00s | ✓ |
| debian-12 | Debian GNU/Linux 12 (bookworm) | 2m 08s | ✓ |
| centos-stream-9 | CentOS Stream 9 | 2m 06s | ✓ |
| centos-stream-10 | CentOS Stream 10 (Coughlan) | 2m 11s | ✓ |
| rocky-9 | Rocky Linux 9.7 (Blue Onyx) | 2m 11s | ✓ |
| rocky-10 | Rocky Linux 10.1 (Red Quartz) | 2m 18s | ✓ |
| alma-9 | AlmaLinux 9.7 (Moss Jungle Cat) | 2m 15s | ✓ |
| alma-10 | AlmaLinux 10.1 (Heliotrope Lion) | 2m 11s | ✓ |
| opensuse-15 | openSUSE Leap 15.6 | 2m 00s | ✓ |

Hetzner Cloud servers are bootstrapped with Ubuntu 22.04 by default.

## SSH Configuration

The nix-infra SSH library (dartssh2) requires specific MAC algorithms that differ from the NixOS defaults. After provisioning, make sure your NixOS configuration includes compatible SSH settings:

```nix
services.openssh.settings.Macs = [
    "hmac-sha2-512-etm@openssh.com"
    "hmac-sha2-512"                  # Required for dartssh
    "hmac-sha2-256-etm@openssh.com"
    "hmac-sha2-256"                  # Required for dartssh
    "umac-128-etm@openssh.com"
  ];
```

This is typically included in the base `configuration.nix` template, but if you encounter SSH connection issues, verify these settings are present.

## Mixed Environments and Migration

You can migrate between providers or use multiple providers simultaneously:

- **Cloud to self-hosted:** Once a Hetzner Cloud server is provisioned and running NixOS, you can add it to `servers.yaml` with a static IP and remove the Hetzner Cloud dependency
- **Self-hosted to cloud:** Create new servers on Hetzner Cloud and gradually migrate workloads
- **Hybrid operation:** Use `servers.yaml` with both static IPs and `provider: hetzner` entries for a mixed fleet

The provider is selected per-project based on the configuration files present. Different projects can use different providers independently.
