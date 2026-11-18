# nix-infra Documentation

nix-infra is a command-line tool for building a private PaaS on Hetzner Cloud or your own servers. It uses NixOS and Nix Packages to create reproducible, auditable infrastructure — giving you full control over costs, privacy, and configuration. Whether you're managing a high-availability cluster or a fleet of standalone machines, nix-infra handles provisioning, deployment, secrets management, and networking through infrastructure-as-code.

## Documentation

| Guide | Description |
|-------|-------------|
| [Architecture](./ARCHITECTURE.md) | How nix-infra works internally — CLI structure, provider abstraction, config substitution, and deployment flow |
| [Providers](./PROVIDERS.md) | Infrastructure providers: Hetzner Cloud, self-hosted servers (`servers.yaml`), and VMware provisioning via nixos-infect |
| [Cluster Guide](./CLUSTER.md) | Setting up and managing HA clusters with etcd, certificates, overlay networking, and service mesh |
| [Fleet Guide](./FLEET.md) | Managing standalone machines or fleets without cluster orchestration |
| [Secrets](./SECRETS.md) | Secrets management — storing, deploying, and managing encrypted secrets |
| [Private Repo Packages](./PRIVATE_REPO_PACKAGES.md) | Building Nix packages from private GitHub/GitLab repositories |
| [Security](./SECURITY.md) | Security model, trust boundaries, encryption, and known limitations |
| [SSH keys](./ARCHITECTURE.md#ssh-keys) | Key files, or keys that stay in an `ssh-agent` with a key map (`SSH_KEY_MAP_PATH`) |

### Design notes

- [SSH keys from an ssh-agent](./design/ssh_agent_keys.md) — design of the agent mode and the key map (implemented)
- [SSH key resolution and keys held by a caller](./analysis/2026-11-17-ssh-key-resolution-external-identities.md) — analysis, 2026-11-17; the variable for one key file that it proposed was removed again (see its status line)
- [MCP servers: SSH keys from a key map](./analysis/2026-11-17-mcp-ssh-key-config.md) — analysis, 2026-11-17; superseded by the design

## Getting Started

See the [main README](../README.md) for installation instructions and quick-start guides.

**Templates to get you started:**

- [nix-infra-ha-cluster](https://github.com/jhsware/nix-infra-ha-cluster) — High-availability cluster with service mesh and overlay networking
- [nix-infra-machine](https://github.com/jhsware/nix-infra-machine) — Standalone machines or fleet management without cluster orchestration
