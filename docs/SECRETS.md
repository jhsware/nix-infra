# Secrets Management

nix-infra provides encrypted secrets management with two deployment modes: **regular secrets** for runtime use via systemd-creds, and **pre-build secrets** for build-time use via tmpfs. Secrets are encrypted locally, stored in your project, and deployed to nodes during `deploy-apps`.

## How Secrets Flow

```mermaid
stateDiagram
direction LR

action : nix-infra action
secret : nix-infra secrets store
local_secrets_enc : secrets/

state cli_deploy {
  local_secrets_dec : secrets/
  ssh
  systemd_credentials : systemd-credentials
  pre_build : /run/keys/ (tmpfs)
}
cli_deploy : nix-infra deploy

action --> local_secrets_enc : encrypt
secret --> local_secrets_enc : encrypt

local_secrets_enc --> cli_deploy
local_secrets_dec --> ssh : decrypt
ssh --> systemd_credentials : encrypt
ssh --> pre_build : pre-build secrets

cli_deploy --> systemd
systemd --> application : decrypt
```

1. **Store** — Secrets are encrypted with OpenSSL and saved in the local `secrets/` directory
2. **Deploy** — During deployment, secrets are decrypted locally, sent over SSH, and re-encrypted on the target using `systemd-creds encrypt`
3. **Runtime** — systemd services decrypt secrets at startup using systemd-creds
4. **Build-time** (pre-build only) — Secrets are also deployed decrypted to `/run/keys/` on tmpfs for the Nix daemon

## Storing Secrets

The `secrets store` command accepts secret values from three sources:

### Inline Value (single-line secrets)

```sh
nix-infra secrets store --name="api-key" --secret="sk-xxxxxxxxxxxxx"
```

### From a File (multi-line secrets)

```sh
nix-infra secrets store --name="github-netrc" --secret-file="./github-netrc"
```

### Piped via stdin

```sh
cat ./github-netrc | nix-infra secrets store --name="github-netrc"
```

The `--secret` and `--secret-file` options are mutually exclusive. If neither is provided and stdin has piped data, it will be read automatically. If no secret is provided from any source, the command exits with an error.

## Storing Action Output as Secrets

When running remote actions (e.g., creating a database user), you can capture the output as a secret:

```sh
# Cluster mode
nix-infra cluster action \
  --target="service001" \
  --app-module="mongodb" \
  --cmd="create-user" \
  --save-as-secret="mongodb-app-credentials"

# Fleet mode
nix-infra fleet action \
  --target="db-server-1" \
  --app-module="postgresql" \
  --cmd="create-user" \
  --save-as-secret="pg-credentials"
```

The action's stdout output is captured, encrypted, and stored as a secret. This only works with a single target node (you cannot save multiple secrets at once).

## Encryption

Secrets are encrypted locally using OpenSSL with PBKDF2 key derivation:

```
openssl enc -pbkdf2 -pass env:SECRETS_PASS -a -out secrets/<name>
```

The encryption password is sourced from:

1. `SECRETS_PWD` in your `.env` file (recommended for automation)
2. Interactive prompt (when running manually)

Encrypted secrets are stored in the `secrets/` directory with file mode `400` (owner read-only). The directory itself is created with mode `700` if it doesn't exist.

## Secret Placeholders in Configuration

Node configuration files use placeholder syntax to reference secrets:

### Regular Secrets

```nix
# In nodes/worker001.nix:
services.myapp.credentialFile = "/root/secrets/[%%secrets/api-key%%]";
```

During deployment, `[%%secrets/api-key%%]` is replaced with the secret name (`api-key`), and the actual encrypted secret file is deployed to `/root/secrets/api-key` on the target node.

### Pre-build Secrets

```nix
# In nodes/worker001.nix:
nix.settings.netrc-file = "/run/keys/[%%pre-build-secrets/github-netrc%%]";
```

Pre-build secrets use the `[%%pre-build-secrets/name%%]` prefix. They are deployed both encrypted (like regular secrets) and decrypted to `/run/keys/` for build-time access.

### Variable Substitution

Secret values can themselves contain placeholders that are resolved during deployment. The substitution system provides these variables:

| Variable | Description |
|----------|-------------|
| `[%%localhost.hostname%%]` | The target node's name |
| `[%%localhost.ipv4%%]` | The target node's public IP |
| `[%%localhost.overlayIp%%]` | The target node's overlay network IP (cluster mode) |
| `[%%nodeName.ipv4%%]` | Any node's public IP by name |
| `[%%nodeName.overlayIp%%]` | Any node's overlay IP by name (cluster mode) |

## Deployment Flow

When `deploy-apps` runs, the deployment pipeline handles secrets automatically:

1. **Scan config files** — The `substitute()` function scans node config files for `[%%secrets/...%%]` and `[%%pre-build-secrets/...%%]` placeholders, building lists of expected secrets
2. **Sync secrets** — `syncSecrets()` processes each expected secret:
   - Reads and decrypts the secret locally using `SECRETS_PWD`
   - Applies variable substitutions (node IPs, overlay IPs, etc.)
   - Deploys the secret encrypted via `systemd-creds encrypt` on the remote node to `/root/secrets/`
3. **Garbage collect** — Any secrets on the remote node that are not in the expected list are removed
4. **Pre-build secrets** — For pre-build secrets, an additional step deploys the decrypted value to `/run/keys/` on tmpfs

If a referenced secret doesn't exist in the local `secrets/` directory, the deployment prints a warning and continues. The warning includes instructions for creating the missing secret.

## Pre-build Secrets

### The Problem

Some NixOS modules need credentials available to the Nix daemon *before* `nixos-rebuild switch` runs. For example, fetching source from private GitHub repositories using `fetchFromGitHub` requires a netrc file.

Regular secrets (deployed encrypted via systemd-creds) are only decrypted at runtime by systemd services. But if the systemd service that decrypts them doesn't exist until after the first successful rebuild, the credentials aren't available yet — a chicken-and-egg problem.

### The Solution

Pre-build secrets are deployed in two ways:

1. **Encrypted** to `/root/secrets/` — For the systemd service to use after rebuild (same as regular secrets)
2. **Decrypted** to `/run/keys/<name>` on tmpfs — For the Nix daemon to use during rebuild

The decrypted files are:

- Written to tmpfs (`/run/keys/`), never to persistent storage
- Set to mode `0400` (root read-only)
- Cleared on reboot or overwritten by the NixOS-managed systemd services after a successful rebuild

### Automatic nix.conf Updates

For secrets containing "netrc" in their name, nix-infra automatically:

1. Appends `netrc-file = /run/keys/<name>` to `/etc/nix/nix.conf` (if not already present)
2. Restarts `nix-daemon` to pick up the new setting

## Example: GitHub PAT as a netrc Pre-build Secret

This is a complete walkthrough for setting up private GitHub repository access during NixOS builds.

### 1. Create the netrc file

```
machine github.com
login x-access-token
password ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Save this as `./github-netrc` (do not commit this file).

### 2. Store it as a secret

```sh
# From a file
nix-infra secrets store --name="github-netrc" --secret-file="./github-netrc"

# Or piped via stdin
cat ./github-netrc | nix-infra secrets store --name="github-netrc"
```

This encrypts the file and stores it in `secrets/github-netrc`.

### 3. Reference it in your node configuration

```nix
# In nodes/worker001.nix:
nix.settings.netrc-file = "/run/keys/[%%pre-build-secrets/github-netrc%%]";
```

### 4. Deploy

```sh
# Cluster mode
nix-infra cluster deploy-apps --target="worker001" --rebuild

# Fleet mode
nix-infra fleet deploy-apps --target="worker001" --rebuild
```

During deployment, nix-infra will:

1. Deploy the secret encrypted to `/root/secrets/github-netrc`
2. Deploy it decrypted to `/run/keys/github-netrc` (mode 0400, root-only, tmpfs)
3. Add `netrc-file = /run/keys/github-netrc` to `/etc/nix/nix.conf`
4. Restart `nix-daemon` to pick up the new setting
5. Run `nixos-rebuild switch` which can now fetch from private GitHub repos

## Security Properties

- **Encryption at rest** — Secrets are encrypted with OpenSSL PBKDF2 in the local `secrets/` directory
- **Encryption in transit** — Secrets are transmitted over SSH
- **Encryption at runtime** — Regular secrets are encrypted on the target with systemd-creds and only decrypted by the owning systemd service
- **Pre-build secrets on tmpfs** — Decrypted material only exists on tmpfs (`/run/keys/`), never on persistent storage, and is cleared on reboot
- **File permissions** — All secret files are mode `0400` (root read-only)
- **Garbage collection** — Unused secrets are automatically removed from target nodes during deployment
- **SECRETS_PWD isolation** — The encryption password is sourced from `.env` or interactive prompt, never stored in configuration files

## Troubleshooting

**"Secret file 'name' not found"** — The secret hasn't been stored yet. Run `nix-infra secrets store --name="name" --secret="value"` to create it.

**"WARNING! Secret 'name' not found in secrets directory, skipping deployment"** — The node config references a secret that doesn't exist locally. The deployment continues but the secret won't be available on the node.

**Wrong SECRETS_PWD** — If the decryption password doesn't match, OpenSSL will produce garbled output or fail. Ensure `SECRETS_PWD` in your `.env` matches what was used when storing the secrets.

**"Cannot specify both --secret and --secret-file"** — The two options are mutually exclusive. Use `--secret` for inline values or `--secret-file` for file contents.
