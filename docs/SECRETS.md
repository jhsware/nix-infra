# Secrets Management

nix-infra provides encrypted secrets management using systemd-creds. Secrets are encrypted locally, stored in your project, and deployed to nodes during `deploy-apps`.


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


1. **Store** — Secrets are encrypted with OpenSSL and saved in the local `secrets/` directory
2. **Deploy** — During deployment, secrets are decrypted locally, sent over SSH, and re-encrypted on the target using `systemd-creds encrypt`
3. **Runtime** — systemd services decrypt secrets at startup using systemd-creds

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

## Reading Secrets

The `secrets read` command decrypts and displays a stored secret. This is useful for verifying secret contents without deploying.

```sh
nix-infra secrets read --name="secrets.netrc/github-netrc"
```

The secret is decrypted using `SECRETS_PWD` and printed to stdout. Use `--batch` to suppress interactive prompts (reads password from `.env` only).

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

### Netrc Secrets (Pre-Build Bootstrap)

```nix
# In nodes/worker001.nix:
infrastructure.netrc-file.credentials = [
  "[%%secrets.netrc/github-netrc%%]"
  "[%%secrets.netrc/gitlab-netrc%%]"
];
```

The `[%%secrets.netrc/<name>%%]` pattern works like regular secrets (deployed encrypted via `syncSecrets`), but additionally triggers a **pre-build bootstrap step**: before `nixos-rebuild switch`, nix-infra decrypts and combines all netrc secrets into `/run/keys/combined-netrc` on the remote machine. This solves the bootstrap problem where `nixos-rebuild` needs netrc credentials to fetch from private repos (e.g., via `builtins.fetchTarball`), but the NixOS module's `ExecStartPre` only runs after a successful rebuild.

See [PRIVATE_REPO_PACKAGES.md](./PRIVATE_REPO_PACKAGES.md) for a detailed guide on building packages from private repositories.

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

1. **Scan config files** — The `substitute()` function scans node config files for `[%%secrets/...%%]` and `[%%secrets.netrc/...%%]` placeholders, building a list of expected secrets (and a separate list of netrc secrets)

2. **Sync secrets** — `syncSecrets()` processes each expected secret:
   - Reads and decrypts the secret locally using `SECRETS_PWD`
   - Applies variable substitutions (node IPs, overlay IPs, etc.)
   - Deploys the secret encrypted via `systemd-creds encrypt` on the remote node to `/root/secrets/`
3. **Bootstrap netrc** — If any `secrets.netrc/` placeholders were found, nix-infra decrypts and combines them into `/run/keys/combined-netrc` (chmod 0400) on the remote machine via SSH. This happens before `nixos-rebuild` so that Nix can authenticate to private repos during the build.
4. **Garbage collect** — Any secrets on the remote node that are not in the expected list are removed

If a referenced secret doesn't exist in the local `secrets/` directory, the deployment prints a warning and continues. The warning includes instructions for creating the missing secret.

## Netrc Credentials for Private Repositories

### The Problem

Some NixOS builds need credentials to fetch source from private repositories (e.g., via `builtins.fetchTarball`). The Nix daemon requires a netrc file to authenticate these requests. However, Nix only supports a single `nix.settings.netrc-file` per machine, so when you have multiple private repository credentials (e.g., GitHub and GitLab), they must be combined into one file.

For a detailed guide on building packages from private repositories, including common pitfalls and the full architecture, see [PRIVATE_REPO_PACKAGES.md](./PRIVATE_REPO_PACKAGES.md).

### The Solution: NixOS Module + systemd LoadCredentialEncrypted

A NixOS module (`modules/netrc.nix`) handles credential management declaratively using systemd's `LoadCredentialEncrypted` and an `ExecStartPre` script:

1. **nix-infra deploys encrypted secrets** to `/root/secrets/` using the `[%%secrets.netrc/...%%]` pattern (which also adds them to `expectedSecrets` for deployment)
2. **The NixOS module configures nix-daemon's systemd service** with:
   - `LoadCredentialEncrypted` entries for each credential, pointing at `/root/secrets/<name>`
   - An `ExecStartPre` script that reads decrypted credentials from `$CREDENTIALS_DIRECTORY/<name>` and combines them into a single netrc file
   - `ExecStopPost` to clean up the decrypted combined file
3. **`nix.settings.netrc-file`** is set declaratively to the combined file path

This approach is self-healing: after reboot or daemon restart, `ExecStartPre` automatically re-creates the combined netrc from encrypted copies.

### Setup

#### 1. Add the NixOS module to your project

Create `modules/netrc.nix` in your infrastructure project:

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.infrastructure.netrc-file;
in
{
  options.infrastructure.netrc-file = {
    target = lib.mkOption {
      type = lib.types.str;
      default = "/run/keys/combined-netrc";
      description = "Path where the combined netrc file will be written.";
    };

    credentials = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        List of encrypted credential names in /root/secrets/ to combine
        into a single netrc file. Each credential is decrypted by systemd
        via LoadCredentialEncrypted and concatenated into the target file.
      '';
    };
  };

  config = lib.mkIf (cfg.credentials != []) {
    systemd.services.nix-daemon.serviceConfig = {
      LoadCredentialEncrypted =
        map (name: "${name}:/root/secrets/${name}") cfg.credentials;

      ExecStartPre = [
        "+${pkgs.writeShellScript "combine-netrc" ''
          set -euo pipefail
          target="${cfg.target}"
          mkdir -p "$(dirname "$target")"
          : > "$target"
          ${lib.concatMapStrings (name: ''
            cat "$CREDENTIALS_DIRECTORY/${name}" >> "$target"
            printf '\n' >> "$target"
          '') cfg.credentials}
          chmod 0400 "$target"
        ''}"
      ];

      ExecStopPost = [
        "+${pkgs.writeShellScript "cleanup-netrc" ''
          rm -f "${cfg.target}"
        ''}"
      ];
    };

    nix.settings.netrc-file = cfg.target;
  };
}
```

Import it from `modules/default.nix`:

```nix
{
  imports = [
    ./netrc.nix
    # ... other modules
  ];
}
```

Since `configuration.nix` (deployed during init) already imports `./modules/default.nix`, the module is available from the very first `nixos-rebuild switch`.

#### 2. Create the netrc files

#### 2. Create the netrc files

```
machine api.github.com
login x-access-token
password ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Save as `./github-netrc` (do not commit this file).

**Important:** The `machine` field must exactly match the hostname in the URL being fetched. For packages using `builtins.fetchTarball` with GitHub API URLs, use `machine api.github.com`. Using `machine github.com` will NOT work — the Nix daemon matches netrc entries by hostname. See [PRIVATE_REPO_PACKAGES.md](./PRIVATE_REPO_PACKAGES.md) for details on hostname matching.

#### 3. Store them as secrets

```sh
nix-infra secrets store --name="github-netrc" --secret-file="./github-netrc"
nix-infra secrets store --name="gitlab-netrc" --secret-file="./gitlab-netrc"
```

#### 4. Reference in your node configuration

```nix
# In nodes/worker001.nix:
infrastructure.netrc-file = {
  target = "/run/keys/combined-netrc";
  credentials = [
    "[%%secrets.netrc/github-netrc%%]"
    "[%%secrets.netrc/gitlab-netrc%%]"
  ];
};
```

After nix-infra substitution, `[%%secrets.netrc/github-netrc%%]` becomes `github-netrc`, and the encrypted secret files are deployed to `/root/secrets/`. Additionally, before `nixos-rebuild switch`, nix-infra decrypts and combines these into `/run/keys/combined-netrc` so credentials are available during the build.

#### 5. Deploy

```sh
# Cluster mode
nix-infra cluster deploy-apps --target="worker001" --rebuild

# Fleet mode
nix-infra fleet deploy-apps --target="worker001" --rebuild
```

During deployment, nix-infra will:

1. Deploy the secrets encrypted to `/root/secrets/github-netrc` and `/root/secrets/gitlab-netrc`
2. Decrypt and combine netrc secrets into `/run/keys/combined-netrc` (bootstrap step)
3. Run `nixos-rebuild switch` (netrc credentials are already available for fetching private repos)
4. On daemon start, systemd decrypts the credentials via `LoadCredentialEncrypted`
5. The `ExecStartPre` script re-creates `/run/keys/combined-netrc` (self-healing after reboots)
6. The Nix daemon uses the combined netrc file to fetch from private repos

### Benefits
- **Multiple credentials** — Combine any number of netrc files into one
- **Self-healing** — After reboot, nix-daemon's ExecStartPre automatically re-creates the combined netrc
- **Daemon restart resilience** — Credentials are re-decrypted on every daemon start
- **NixOS-native** — Uses systemd-creds and NixOS service configuration declaratively
- **Bootstrap support** — The `secrets.netrc/` pattern ensures credentials are available before the first `nixos-rebuild switch`, solving the chicken-and-egg problem on clean installs
- **No bootstrap issues** — Module is deployed as part of base infrastructure during init


## Security Properties

- **Encryption at rest** — Secrets are encrypted with OpenSSL PBKDF2 in the local `secrets/` directory
- **Encryption in transit** — Secrets are transmitted over SSH
- **Encryption at runtime** — Secrets are encrypted on the target with systemd-creds and only decrypted by the owning systemd service

- **File permissions** — All secret files are mode `0400` (root read-only)
- **Garbage collection** — Unused secrets are automatically removed from target nodes during deployment
- **SECRETS_PWD isolation** — The encryption password is sourced from `.env` or interactive prompt, never stored in configuration files

## Troubleshooting

**"Secret file 'name' not found"** — The secret hasn't been stored yet. Run `nix-infra secrets store --name="name" --secret="value"` to create it.

**"WARNING! Secret 'name' not found in secrets directory, skipping deployment"** — The node config references a secret that doesn't exist locally. The deployment continues but the secret won't be available on the node.

**Wrong SECRETS_PWD** — If the decryption password doesn't match, OpenSSL will produce garbled output or fail. Ensure `SECRETS_PWD` in your `.env` matches what was used when storing the secrets.

**"Cannot specify both --secret and --secret-file"** — The two options are mutually exclusive. Use `--secret` for inline values or `--secret-file` for file contents.
