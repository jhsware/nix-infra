# nix-infra

I believe there is a future for private PaaS-solutions in a world where privacy and cost-control are primary concerns. We just needs to build it on the right foundation.

Create a private PaaS on Hetzner Cloud in minutes using nix-infra. Leverage NixOS and Nix Packages to build a reproducable and auditable private cloud platform for your projects.

Why did I build this? I wanted to test the limits of NixOS when it comes to maintainability and real world use.

- low and predictable cost -- runs on Hetzner Cloud
- reproducable and auditable -- 100% configuration in code
- guaranteed privacy -- all data within your walled garden
- easy to debug -- zero blackbox services
- extendable -- install anything than runs on NixOS or as an OCI-container
- customise in any way you like

You can easily share and extend modules to build the perfect private PaaS while using your favourite OS and package repository.

Low system requirements for each cluster node makes virtual machine isolation per service/application cost effective.

Features:
- runs NixOS as host OS
- uses Systemd credentials to secure secrets
- fault tolerant service mesh (with HAProxy + Etcd + Confd)
- private encrypted overlay network (with flanneld + wireguard)
- supports provisioning nodes in multiple data centers
- run apps in OCI-containers with podman

Limitations:
- NixOS doesn't support SELinux
- nix-infra currently only supports Hetzner Cloud
- the code is the primary documentation

Room for improvement:
- hardening with AppArmor [major]
- encryption of config folder at rest [medium]
- rotating secrets [medium]
- virtual tpm for systemd-credentials (not supported by Hetzner cloud)
- visualise cluster health [major]

Apple discusses privacy in a post about [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/).

## Getting Started
```sh
$ git clone git@github.com:jhsware/nix-infra-test.git
# Read the instructions in the cloned README.md
$ nix-infra init -d ./nix-infra-test
```

## Configure With Nix
Configure your cluster using the **Nix** language.

Add remote actions written in **Bash** that can be run on cluster nodes. If you prefer you
could use any scripting language that is available on your cluster nodes.

If you want to extend, customise or contribute to the provisioning and orchestration CLI
you need write **Dart**. I chose because it is cross-platform, supports running interpreted
or as a compiled application which greatly enhances the development experience.

```mermaid
stateDiagram
direction LR

Template --> Repo.0 : git clone
Repo.0 --> Repo.1 : nix-infra init
Repo.1 --> Repo.2 : manual configure<br>ssh-add
Repo.2 --> Cluster.1 : nix-infra provision<br>nix-infra init-ctrl<br>nix-infra init-node
Repo.2 --> Repo.3 : configure apps
Repo.3 --> Cluster.2 : nix-infra deploy

```

### Cluster Setup
To create similar clusters you create a template configuration and fork it for each cluster.

To share app configurations you copy them to your cluster repo.

To create an exact copy of cluster, use the same cluster repo but different .env-files.
```mermaid
stateDiagram
direction LR

Template.1 --> Repo.1 : Clone a Cluster Template
Repo.1 --> Repo.2 : Configure Cluster

Repo.2 --> Cluster.1 : Deploy Cluster
Repo.2 --> Repo.3 : Copy App Modules

Repo.3 --> Repo.4 : Configure Applications

Repo.4 --> Cluster.2 : Deploy Apps
Repo.4 --> Repo.5

Template.2 --> Repo.5 : Rebase/Merge/Pick
Repo.5 --> Cluster.3 : Update Cluster

```

### Cluster Configuration

Provisioning of nodes, deployment of configurations and container images is done through the nix_infra CLI. The overlay network and service mesh is configured via the etcd-database of the control plane (ctrl).

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

### Nix Packages and Container Images
The registry node contains a package cache and registry which allows you to
provide private packages and caching.

The registry node also contains a container image registry where you push
your private application images.

```mermaid
stateDiagram

registry --> service : img/pkg
registry --> worker : img/pkg
registry --> ingress : img/pkg
```

### Service Overview
The cluster has a simple topology with three layers. Only the ingress layer
is exposed to the outside world.

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

#### Services
Stateful services such as DBs run on the service nodes.

#### Workers
Worker nodes that run your stateless application containers.

#### Ingress
The ingress node exposes the cluster to the internet via an Nginx reverse proxy.

## Development Notes
Testing:
```sh
scripts/end-to-end-tests/test-nix-infra-ha-cluster.sh --env=./.env
scripts/end-to-end-tests/test-nix-infra-test.sh --env=./.env
```

- should deployAppsOnNode really "Send modules to the node"?
- should deployAppsOnNode perform cleanup of removed files?

A sample command-line application with an entrypoint in `bin/`, library code
in `lib/`, and example unit test in `test/`.

```sh
provision () { nix-infra provision -d ../TEST -c ../TEST/cluster.cfg --node-names="$@" }
init-ctrl() { nix-infra init-ctrl -d ../TEST -c ../TEST/cluster.cfg }
init-node() { nix-infra init-node -d ../TEST -c ../TEST/cluster.cfg --target="$@" }
init-ingress() { nix-infra init-ingress -d ../TEST -c ../TEST/cluster.cfg --target=$1 }
destroy () { nix-infra destroy -d ../TEST -c ../TEST/cluster.cfg --target="$@" }
cluster-ssh () { nix-infra ssh -d ../TEST -c ../TEST/cluster.cfg --target="$1" }
cluster-cmd () { local target="$1"; shift 1; nix-infra cmd -d ../TEST -c ../TEST/cluster.cfg --target="$target" "$@" }

cluster-cmd () { local target="$1"; shift 1; echo "$@"; ./cluster.sh --cluster=./cluster.cfg --working-dir=`pwd` cmd --target=$target "$@" }
cluster-ssh () { ./cluster.sh --cluster=./cluster.cfg --working-dir=`pwd` ssh --target="$1" }

```


## etcd data model

```JavaScript
/cluster/frontends
    [app_name]/
      instances/
        [node_name]={
          "node": "[node_name]",
          "ipv4": "123.23.23.0",
          "port": 123
        }
      meta_data={
        publish: { ”port”: 5001 } // Used by HA proxy to expose service on worker nodes
        env_prefix: "[PREFIX]"
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
        publish: { ”port”: 5001 } // Used by HA proxy to expose service on worker nodes
        env_prefix: "[PREFIX]"
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
        publish: { ”port”: 5001 } // Used by HA proxy to expose service on worker nodes
        env_prefix: "[PREFIX]"
        env: { "PROTOCOL", "HOST", "PORT", "PATH" }
      }

/cluster/nodes
    [node_name]={
      "name": "[node_name]",
      "ipv4": "123.23.23.9",
      "services": ["services", "frontends", "backends"] // Service types to access
    }
```
### Node Lifecycle

1. Provision node
2. Initialise node
3. Resister node
4. Unregister node
5. Destroy node

### App Lifecycle

CONSIDER: We might want to provide some kind of CI/CD-pipeline

1. Register app
2. Deploy app to node
3. Register app instance
4. Unregister app instance
5. Remove app from node
6. Unregister app

## Secrets

Secrets are created either:
- by storing the result of an action (i.e. when you create a user in a db), or
- by explicitly storing a provided secret (i.e. an external API-key)

```sh
nix_infra.dart [...] action [...] --store-as-secret="[secret-name]"
nix_infra.dart [...] store-secret [...] --secret="[your-secret]" --store-as-secret="[secret-name]"
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


## Internal Developer Notes
TODO: Investigate secret rotation
  - https://partial.solutions/2024/understanding-systemd-credentials.html
TODO: Automated builds
  - https://blog.thestateofme.com/2023/05/17/multi-architecture-automated-builds-for-dart-binaries/

TODO: Font
  - https://www.dafont.com/aristotelica.font?text=nix-infra
  - https://fonts.google.com/specimen/Comfortaa?preview.text=nix-infra&categoryFilters=Sans+Serif:%2FSans%2FRounded

DONE: Investigate using systemd credentials 
  - https://dee.underscore.world/blog/systemd-credentials-nixos-containers/

INVESTIGATE: Securing systemd services
  - https://documentation.suse.com/smart/security/pdf/systemd-securing_en.pdf

INVESTIGATE: Tuning kernel and HAProxy
  - https://medium.com/@pawilon/tuning-your-linux-kernel-and-haproxy-instance-for-high-loads-1a2105ea553e

DONE: Investigate Nixos secrets management
  - https://nixos.wiki/wiki/Comparison_of_secret_managing_schemes
  - secrix appears to have systemd integration

DONE: Investigate using agenix for secrets
  - https://nixos.wiki/wiki/Agenix
  - https://github.com/ryantm/agenix
  - https://github.com/FiloSottile/age
