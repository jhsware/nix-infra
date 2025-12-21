# Integration Tests

This directory contains integration tests for nix-infra. The tests validate that the nix-infra CLI works correctly against real infrastructure.

## Prerequisites

- The `nix-infra` CLI installed and available in your PATH (or set `NIX_INFRA` env var to point to it)
- A Hetzner Cloud account with API access
- `jq` and `curl` installed
- SSH keys for the test infrastructure

## Setup

1. **Create the environment file**

   Create a `.env` file in the `provisioning/` directory:

```bash
cp __integration__/.env.in __integration__/.env  # or create manually
```
2. **SSH keys**

  SSH keys are automatically generated for you if missing and added to `./ssh/`. The test script will add it to SSH agent.

3. **Server configuration**

   The test uses a pre-configured server defined in `servers.yaml`. The server ID must be set in servers.yaml.

## Provisioning Test

The provisioning test (`__integration__/provisioning/`) validates that nix-infra can convert various Linux distributions to NixOS. It uses an existing server on Hetzner Cloud that gets rebuilt with different base images and then converted to NixOS.

```bash
provisioning/test-provisioning.sh --help
```

## Configuration Options

Environment variables that can be set before running tests:

| Variable | Default | Description |
|----------|---------|-------------|
| `WORK_DIR` | Script directory | Working directory for test files |
| `NIX_INFRA` | `nix-infra` | Path to nix-infra CLI |
| `NIXOS_VERSION` | `25.05` | NixOS version to install |
| `SSH_KEY` | `nixinfra` | SSH key name |
| `SSH_EMAIL` | `your-email@example.com` | Email for SSH key |
| `SECRETS_PWD` | `my_secrets_password` | Password for secrets encryption |
| `TEST_NODES` | `testnode001` | Space-separated list of test nodes |

## Troubleshooting

- **"Missing env-var HCLOUD_TOKEN"**: Ensure your `.env` file exists and contains `HCLOUD_TOKEN`
- **SSH connection failures**: Make sure the correct SSH key has been added to your agent
- **"Found existing ./secrets"**: The convert command won't run if a `secrets/` directory exists to prevent accidentally destroying a live project. Remove it manually if this is intentional.
