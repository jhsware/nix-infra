# nix-infra

Create a private PaaS on Hetzner Cloud or your own servers in minutes. Leverage **NixOS** and **Nix Packages** to build a reproducible and auditable private cloud for your projects.

**Why nix-infra?** You want to move away from click-ops and embrace infrastructure-as-code and reproducibility. You want to avoid vendor lock-in and unpredictable cloud bills. There is a future for private PaaS solutions in a world where privacy and cost control are primary concerns, we just need to build it on a robust foundation.

## Benefits

- **Low and predictable cost** — provision from scratch on Hetzner Cloud or deploy to your existing servers via SSH
- **Reproducible and auditable** — 100% configuration in code
- **Privacy** — all data within your private walled garden
- **Easy to debug** — zero blackbox services
- **Extensible** — install anything that runs on NixOS or as an OCI container
- **Customisable** — modify and share modules to build your perfect private PaaS

## Features

- **Fleet mode** — manage standalone NixOS machines or groups of independent servers
- **Cluster mode** — HA clusters with etcd, encrypted overlay network (Flanneld + WireGuard), and service mesh (HAProxy + confd)
- **Secrets management** — encrypted secrets with OpenSSL pbkdf2, three input methods (inline, file, stdin), systemd-creds runtime decryption
- **Provider abstraction** — Hetzner Cloud and self-hosted servers (including VMware via nixos-infect mutations), with automatic detection
- **Container registry** — private OCI image distribution
- **MCP servers** — experimental AI-assisted infrastructure management via Claude or other MCP-compatible assistants

## Getting Started

### Prerequisites

- [Download](https://github.com/jhsware/nix-infra/releases) and install the nix-infra binary
- SSH and OpenSSL installed on your workstation
- A Hetzner Cloud API token or existing servers accessible via SSH

### Choose Your Setup

**Option 1: High-availability cluster**

Use the [nix-infra-ha-cluster](https://github.com/jhsware/nix-infra-ha-cluster) template for a fault-tolerant multi-node cluster with service mesh and overlay networking.

**Option 2: Fleet of standalone machines**

Use the [nix-infra-machine](https://github.com/jhsware/nix-infra-machine) template for managing individual machines or fleets without cluster orchestration.

Each template contains detailed instructions. You can either run the provided test script to automate installation, or clone the repo and create custom automation scripts.

## Documentation

Comprehensive documentation is available in the [`docs/`](./docs/) directory:

| Guide | Description |
|-------|-------------|
| [Documentation Home](./docs/README.md) | Entry point with overview and navigation |
| [Architecture](./docs/ARCHITECTURE.md) | How nix-infra works internally — CLI structure, provider abstraction, deployment flow, service mesh |
| [Providers](./docs/PROVIDERS.md) | Infrastructure providers — Hetzner Cloud, self-hosted servers, hybrid mode, VMware provisioning |
| [Fleet Guide](./docs/FLEET.md) | Managing standalone machines — setup, commands, day-2 operations |
| [Cluster Guide](./docs/CLUSTER.md) | HA clusters — control plane, worker nodes, etcd, service topology |
| [Secrets](./docs/SECRETS.md) | Secrets management — encryption, storage, deployment, pre-build secrets |
| [Security](./docs/SECURITY.md) | Security model — transport, encryption, PKI, known limitations, recommendations |

## Building From Source

1. Install Nix (choose one):
   - https://nixos.org/download/
   - https://github.com/DeterminateSystems/nix-installer (supports uninstall)

2. Clone and build:
```sh
git clone git@github.com:jhsware/nix-infra.git
cd nix-infra && ./build.sh
# output: bin/nix-infra
```

Requires Dart — you can use `nix-shell -p dart` to get it.

## Development

### Testing

```sh
scripts/end-to-end-tests/test-nix-infra-ha-cluster.sh --env=./.env
scripts/end-to-end-tests/test-nix-infra-test.sh --env=./.env
```

### Internal Developer Notes

#### Releasing

1. Update version in pubspec.yaml
2. Build macOS binary: `./build.sh build-macos --env=.env`
3. Package and notarise macOS binary
4. Run build workflow to create draft release with Linux binary
5. Add macOS binary to release
6. Add release notes
7. Publish release

#### References

- [Secret rotation with systemd credentials](https://partial.solutions/2024/understanding-systemd-credentials.html)
- [Multi-architecture automated builds for Dart](https://blog.thestateofme.com/2023/05/17/multi-architecture-automated-builds-for-dart-binaries/)
- [Securing systemd services](https://documentation.suse.com/smart/security/pdf/systemd-securing_en.pdf)
- [Tuning kernel and HAProxy](https://medium.com/@pawilon/tuning-your-linux-kernel-and-haproxy-instance-for-high-loads-1a2105ea553e)
- [NixOS secrets comparison](https://nixos.wiki/wiki/Comparison_of_secret_managing_schemes)
- [systemd credentials on NixOS](https://dee.underscore.world/blog/systemd-credentials-nixos-containers/)
