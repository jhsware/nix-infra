# nix-infra

Create a private PaaS on Hetzner Cloud in minutes. Leverage **NixOS** and **Nix Packages** to build a reproducible and auditable private cloud for your projects.

**Why nix-infra?** I wanted to test the limits of NixOS when it comes to maintainability and real-world use. There is a future for private PaaS solutions in a world where privacy and cost control are primary concerns—we just need to build it on the right foundation.

> **Experimental:** nix-infra now includes [MCP server support](#mcp-server-experimental) for AI-assisted infrastructure management. Query node status, inspect logs, and manage your fleet through natural language conversations with Claude or other MCP-compatible AI assistants. This is an early experiment in making Linux system administration more accessible and efficient.

**Benefits:**

- **Low and predictable cost** — runs on Hetzner Cloud
- **Reproducible and auditable** — 100% configuration in code
- **Privacy** — all data within your private walled garden
- **Easy to debug** — zero blackbox services
- **Extensible** — install anything that runs on NixOS or as an OCI container
- **Customisable** — modify and share modules to build your perfect private PaaS

Low system requirements for each cluster node make virtual machine isolation per service/application cost-effective.

**Features:**

- NixOS as host OS
- Systemd credentials for secure secrets management
- Fault-tolerant service mesh (HAProxy + etcd + confd)
- Private encrypted overlay network (Flanneld + WireGuard)
- Multi-datacenter node provisioning
- OCI container support with Podman

**Limitations:**

- NixOS doesn't officially support SELinux (though [experimental work is underway](https://tristanxr.com/post/selinux-on-nixos/))
- nix-infra currently only supports Hetzner Cloud
- The code is the primary documentation

**Room for improvement:**

- Hardening with AppArmor [major]
- Encryption of config folder at rest [medium]
- Rotating secrets [medium]
- Virtual TPM for systemd-credentials (not supported by Hetzner Cloud)
- Cluster health visualisation [major]

Apple discusses privacy in a post about [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/).

## Getting Started

### Prerequisites

Install Nix on your machine to work in a nix-shell. If you don't have Nix installed, try the [Determinate Systems Nix installer](https://github.com/DeterminateSystems/nix-installer)—it has uninstall support and automatic garbage collection.

[Download](https://github.com/jhsware/nix-infra/releases) and install the nix-infra binary. Clone this repo and run `nix-shell` to ensure you get [the right version](https://github.com/jhsware/nix-infra/blob/main/nix/hcloud.nix) of the `hcloud` tool.

### Choose Your Setup

**Option 1: High-availability cluster**

Use the [nix-infra-ha-cluster](https://github.com/jhsware/nix-infra-ha-cluster) template for a fault-tolerant multi-node cluster with service mesh and overlay networking.

**Option 2: Standalone machines**

Use the [nix-infra-machine](https://github.com/jhsware/nix-infra-machine) template for managing individual machines or fleets without cluster orchestration.

Each repo contains detailed instructions. You can either run the provided test script to automate installation, or clone the repo and create custom automation scripts.

## Building From Source

1. Install Nix (choose one):
   - https://nixos.org/download/
   - https://github.com/DeterminateSystems/nix-installer (supports uninstall)

2. Clone the repo:
```sh
git clone git@github.com:jhsware/nix-infra.git
```

3. Build using the build script:
```sh
cd nix-infra && ./build.sh
# output: bin/nix-infra
```

## Creating a Cluster

Configure your cluster using the **Nix** language. Add remote actions written in **Bash** that can be run on cluster nodes.

### Quick Start

1. Clone a cluster template
2. Run `nix-infra init` to create the cluster configuration folder
3. Create a `.env` file with your Hetzner API token
4. Add the created SSH key to the ssh agent (`ssh-add`)
5. Provision nodes: `nix-infra provision`
6. Initialise control plane: `nix-infra init-ctrl`
7. Initialise cluster nodes: `nix-infra init-node`
8. Configure apps (apps consist of app_module and node-specific configuration)
9. Deploy apps: `nix-infra deploy`

### Cluster Setup Patterns

**Fork a template for each cluster:**

```mermaid
stateDiagram
direction LR

Cluster_1: Cluster 1
Cluster_2: Cluster 2
Template --> Cluster_1
Template --> Cluster_2
```

**Share apps between clusters by copying modules:**

```mermaid
stateDiagram-v2
direction LR

Cluster_1: Cluster 1
Cluster_2: Cluster 2
Template --> Cluster_1
Template --> Cluster_2
Cluster_1 --> Cluster_2 : copy<br>app_modules/mongodb.nix<br>app_modules/keydb.nix
```

**Create exact copies using the same repo with different .env files:**

```mermaid
stateDiagram-v2
direction LR

Cluster_1: Cluster 1
Template --> Cluster_1
note left of Cluster_1 : .env-a
note left of Cluster_1 : .env-b
```

### Configuration Files

The main configuration files you'll work with once your cluster is running:

- `nodes/[node_name].nix` — install and configure apps on each node
- `app_modules/[module_name].nix` — define apps available on the cluster

When you add new files to app_modules, import them in `app_modules/default.nix`.

```mermaid
stateDiagram-v2
direction LR

flake: flake.nix
configuration: configuration.nix
hardwareConfiguration: hardware-configuration.nix
networking: networking.nix
nodeType: node_types/[node_type].nix
nodeConfig: nodes/[node_name].nix
modules: modules/[module_name].nix
appModules: app_modules/[module_name].nix

NixPkgs --> flake
Secrix --> flake

flake --> configuration : modules

configuration --> generated
configuration --> nodeType
configuration --> nodeConfig
configuration --> modules
configuration --> appModules

state generated {
  direction LR
  hardwareConfiguration
  networking
}
```

### Cluster Provisioning

Node provisioning, configuration deployment, and container image management are handled through the nix-infra CLI. The overlay network and service mesh are configured via the etcd database on the control plane.

```mermaid
stateDiagram-v2

ctrl_node --> cluster_node : overlay network config<br>service mesh config
CLI --> ctrl_node : provision
CLI --> cluster_node : provision
CLI --> ctrl_node : deploy
CLI --> cluster_node : deploy

state ctrl_node {
  etcd
  systemd_ctrl
  state  "systemd" as systemd_ctrl
}

state cluster_node {
  haproxy
  confd
  systemd
  flanneld
}
```

### Package Cache and Container Registry

The registry node contains a package cache and container image registry for distributing private packages and application images.

```mermaid
stateDiagram

registry --> service : img/pkg
registry --> worker : img/pkg
registry --> ingress : img/pkg
```

### Service Topology

The cluster has three layers. Only the ingress layer is exposed to the outside world.

```mermaid
stateDiagram

service: Services
worker: Workers
ingress: Ingress

service --> worker
worker --> ingress
ingress

state service {
  mongodb: MongoDB
  keydb: KeyDB
  elasticsearch: Elasticsearch
}

state worker {
  API: API / Backend
  APP: APP / Frontend
}

state ingress {
  reverse_proxy: Nginx
}
```

**Services:** Stateful services such as databases run on service nodes.

**Workers:** Stateless application containers run on worker nodes.

**Ingress:** The ingress node exposes the cluster to the internet via an Nginx reverse proxy.

## MCP Server (Experimental)

nix-infra includes experimental [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) servers that enable AI assistants like Claude to query and manage your infrastructure through natural conversation.

The vision is to provide an assistant that is more natural and efficient to use than complex GUI environments, while leveraging well-known Linux system administration tools available on the server by default. Instead of memorising command syntax or navigating dashboards, you can ask questions like "What's the health status of my service nodes?" or "Show me the recent logs for nginx".

### Two MCP Servers

- **nix-infra-cluster-mcp** — For HA clusters with etcd control plane
- **nix-infra-machine-mcp** — For standalone machines or fleets

### Available Tools

| Tool | Description | Cluster | Machine |
|------|-------------|:-------:|:-------:|
| `list-available-nodes` | List all nodes with Hetzner ID, name, and IP | ✓ | ✓ |
| `system-stats` | Query system health, disk I/O, memory, network, and processes | ✓ | ✓ |
| `systemctl` | Query systemd unit status (read-only) | ✓ | ✓ |
| `journalctl` | Query systemd journal logs (read-only) | ✓ | ✓ |
| `remote-command` | Execute whitelisted commands over SSH | ✓ | ✓ |
| `configuration-files` | Read local configuration files | ✓ | ✓ |
| `test-runner` | Run tests on existing test cluster | ✓ | ✓ |
| `etcd` | Query the etcd control plane (read-only) | ✓ | — |

### Safety Measures

The MCP servers implement several layers of protection:

- **Command parsing and validation** — All commands are parsed and inspected before execution
- **Read-only restrictions** — Tools like `systemctl`, `journalctl`, and `etcd` only allow read operations
- **Whitelists and blacklists** — Remote commands are filtered against allowed/blocked command lists
- **Path restrictions** — Filesystem operations are confined to the project directory with no absolute paths or hidden files

### Security Considerations

> ⚠️ **Be mindful of prompt injection.** The MCP executes shell commands on your infrastructure. While safety measures are in place, this is inherently a challenging security problem.
>
> **Assume you can destroy your environment at any time and prepare accordingly.** Maintain backups and ensure you can restore your infrastructure.

### Usage

The cluster templates include a `./cli claude` command that launches Claude with the MCP server configured. See the [nix-infra-ha-cluster](https://github.com/jhsware/nix-infra-ha-cluster) or [nix-infra-machine](https://github.com/jhsware/nix-infra-machine) repositories for setup instructions.

## Secrets

Secrets are created either by storing the result of an action (e.g., when creating a database user) or by explicitly storing a provided secret (e.g., an external API key).

```sh
# Store action output as a secret
nix-infra [...] action [...] --store-as-secret="[secret-name]"

# Store a provided secret
nix-infra [...] store-secret [...] --secret="[your-secret]" --store-as-secret="[secret-name]"
```

```mermaid
stateDiagram
direction LR

action : nix-infra action
secret : nix-infra secret
local_secrets_enc : secrets/

state cli_deploy {
  local_secrets_dec : secrets/
  ssh
  systemd_credentials : systemd-credentials
}
cli_deploy : nix-infra deploy

action --> local_secrets_enc : encrypt
secret --> local_secrets_enc : encrypt

local_secrets_enc --> cli_deploy
local_secrets_dec --> ssh : decrypt
ssh --> systemd_credentials : encrypt

cli_deploy --> systemd
systemd --> application : decrypt
```

## Development

### Testing

```sh
scripts/end-to-end-tests/test-nix-infra-ha-cluster.sh --env=./.env
scripts/end-to-end-tests/test-nix-infra-test.sh --env=./.env
```

### etcd Data Model

```javascript
/cluster/frontends
    [app_name]/
      instances/
        [node_name]={
          "node": "[node_name]",
          "ipv4": "123.23.23.0",
          "port": 123
        }
      meta_data={
        publish: { "port": 5001 },    // HAProxy uses this to expose service on worker nodes
        env_prefix: "[PREFIX]",
        env: { "PROTOCOL", "HOST", "PORT", "PATH" }
      }

/cluster/backends
    [app_name]/
      instances/
        [node_name]={
          "node": "[node_name]",
          "ipv4": "123.23.23.0",
          "port": 123
        }
      meta_data={
        publish: { "port": 5001 },
        env_prefix: "[PREFIX]",
        env: { "PROTOCOL", "HOST", "PORT", "PATH" }
      }

/cluster/services
    [app_name]/
      instances/
        [node_name]={
          "node": "[node_name]",
          "ipv4": "123.23.23.0",
          "port": 123
        }
      meta_data={
        publish: { "port": 5001 },
        env_prefix: "[PREFIX]",
        env: { "PROTOCOL", "HOST", "PORT", "PATH" }
      }

/cluster/nodes
    [node_name]={
      "name": "[node_name]",
      "ipv4": "123.23.23.9",
      "services": ["services", "frontends", "backends"]  // Service types to access
    }
```

### Node Lifecycle

1. Provision node
2. Initialise node
3. Register node
4. Unregister node
5. Destroy node

### App Lifecycle

1. Register app
2. Deploy app to node
3. Register app instance
4. Unregister app instance
5. Remove app from node
6. Unregister app

## Internal Developer Notes

### Releasing

1. Update version in pubspec.yaml

2. Build macOS binary:
```sh
./build.sh build-macos --env=.env
```

3. Package and notarise macOS binary

4. Run build workflow to create draft release with Linux binary

5. Add macOS binary to release

6. Add release notes

7. Publish release

### References

**Secret rotation:**
- https://partial.solutions/2024/understanding-systemd-credentials.html

**Automated builds:**
- https://blog.thestateofme.com/2023/05/17/multi-architecture-automated-builds-for-dart-binaries/

**Fonts:**
- https://www.dafont.com/aristotelica.font?text=nix-infra
- https://fonts.google.com/specimen/Comfortaa?preview.text=nix-infra

**Systemd credentials:**
- https://dee.underscore.world/blog/systemd-credentials-nixos-containers/

**Securing systemd services:**
- https://documentation.suse.com/smart/security/pdf/systemd-securing_en.pdf

**Tuning kernel and HAProxy:**
- https://medium.com/@pawilon/tuning-your-linux-kernel-and-haproxy-instance-for-high-loads-1a2105ea553e

**NixOS secrets management:**
- https://nixos.wiki/wiki/Comparison_of_secret_managing_schemes
- https://nixos.wiki/wiki/Agenix
- https://github.com/ryantm/agenix
- https://github.com/FiloSottile/age
