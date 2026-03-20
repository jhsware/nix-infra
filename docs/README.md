# nix-infra Documentation

nix-infra is a command-line tool for building a private PaaS on Hetzner Cloud or your own servers. It uses NixOS and Nix Packages to create reproducible, auditable infrastructure — giving you full control over costs, privacy, and configuration. Whether you're managing a high-availability cluster or a fleet of standalone machines, nix-infra handles provisioning, deployment, secrets management, and networking through infrastructure-as-code.

## Documentation

| Guide | Description |
|-------|-------------|
| [Architecture](./ARCHITECTURE.md) | How nix-infra works internally — CLI structure, provider abstraction, config substitution, and deployment flow |
| [Providers](./PROVIDERS.md) | Infrastructure providers: Hetzner Cloud, self-hosted servers (`servers.yaml`), and VMware provisioning via nixos-infect |
| [Cluster Guide](./CLUSTER.md) | Setting up and managing HA clusters with etcd, certificates, overlay networking, and service mesh |
| [Fleet Guide](./FLEET.md) | Managing standalone machines or fleets without cluster orchestration |
| [Secrets](./SECRETS.md) | Secrets management — storing, deploying, and managing secrets including pre-build secrets |
| [Security](./SECURITY.md) | Security model, trust boundaries, encryption, and known limitations |

## Getting Started

See the [main README](../README.md) for installation instructions and quick-start guides.

**Templates to get you started:**

- [nix-infra-ha-cluster](https://github.com/jhsware/nix-infra-ha-cluster) — High-availability cluster with service mesh and overlay networking
- [nix-infra-machine](https://github.com/jhsware/nix-infra-machine) — Standalone machines or fleet management without cluster orchestration
