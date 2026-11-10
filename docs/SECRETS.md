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


1. **Store** — Secrets are encrypted with AES-256-GCM (`nix-infra-secret/v2`, see [Encryption](#encryption)) and saved in the local `secrets/` directory
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

### Replacing a secret

`secrets store` does not replace an existing secret; it exits with an error. Add `--overwrite` to replace it:

```sh
nix-infra secrets store --name="api-key" --secret="sk-yyyyyyyyyyyyy" --overwrite
```

## Reading Secrets

The `secrets read` command decrypts and displays a stored secret. This is useful for verifying secret contents without deploying.

```sh
nix-infra secrets read --name="github-netrc"
```

The secret is decrypted using `SECRETS_PASS` and printed to stdout. Use `--batch` to suppress interactive prompts (reads the key from `.env` or the environment only). A secret that cannot be read (wrong key, damaged file, unknown format) prints an error and exits with code 1.

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

Secrets are encrypted locally, in the nix-infra process (OpenSSL is no longer used), and written to `secrets/<name>` as `nix-infra-secret/v2` files. The value is never passed to a child process and never written to disk in plaintext.

```text
nix-infra-secret/v2
kind: text | github-netrc
created: <UTC ISO 8601, seconds>
kdf: hkdf-sha256 | pbkdf2-hmac-sha256
iterations: <only for pbkdf2>
salt: <base64, 16 bytes>
cipher: aes-256-gcm
nonce: <base64, 12 bytes>
key_id: <8 hex, only for hkdf>
---
<base64 of ciphertext and 16-byte tag, 64 characters per line>
```

- **Cipher** — AES-256-GCM with a new random salt and nonce for every file. The header (everything before `---`) is the authenticated data, so a changed header or body makes decryption fail instead of returning a wrong value.
- **kind** — `github-netrc` when the value is one netrc entry `machine api.github.com login x-access-token password <token>`, else `text`.
- **created** — When the value was stored. `secrets migrate` keeps it, or uses the modification time of the old file.

The key is `SECRETS_PASS`, sourced from:

1. `SECRETS_PASS` in your `.env` file or the environment (recommended for automation; `SECRETS_PWD` still works but is deprecated)
2. Interactive prompt (when running manually)

### Generated files key or password

`SECRETS_PASS` can be one of two kinds of key:

| | Generated files key (recommended) | Password |
|---|---|---|
| Looks like | `nisk1_` followed by 43 base64url characters (256 random bits) | Any other text |
| Made with | `nix-infra secrets new-key` | You choose it |
| Key derivation | HKDF-SHA256 (instant) | PBKDF2-HMAC-SHA256, 600000 iterations |
| Time per secret | Milliseconds | About 2.4 s per derivation (measured on a developer laptop); storing a secret derives twice (encrypt and read-back check), about 5 s |
| `key_id` in the header | Yes: a wrong key is reported before decryption | No |

A generated key is stronger and much faster. A password is accepted so that existing projects keep working; to change to a generated key, see [Changing the files key](#changing-the-files-key).

Secret files are stored in the `secrets/` directory with file mode `400` (owner read-only). The directory itself is created with mode `700` if it doesn't exist. Each file is written atomically: to a temporary file `secrets/.tmp-<random>` (mode 600), read back and decrypted to check it, then renamed into place.

**Keep `secrets/` out of version control.** The project templates (`nix-infra-machine`, `nix-infra-ha-cluster`) have `secrets/*` in `.gitignore`; keep it there. Files made by earlier versions are not encrypted (see below), and even v2 files are only as strong as the key.

## Formats that nix-infra reads

nix-infra reads three formats and writes only v2:

| Format | `secrets list` shows | What it is | Key needed to read |
|---|---|---|---|
| `nix-infra-secret/v2` | `v2` | AES-256-GCM, described above | Yes |
| Legacy OpenSSL | `openssl` | `openssl enc -aes-256-cbc [-pbkdf2] -a` output (`Salted__`, AES-256-CBC). nix-infra tries, in order, PBKDF2-HMAC-SHA256 with 10000 iterations, EVP_BytesToKey with SHA-256 and EVP_BytesToKey with MD5 | Yes |
| Legacy base64 | `plain` | Base64 of the plain value | No |

> **Warning: secret files made by nix-infra before 0.18.0-beta are NOT encrypted.** Earlier versions ran `openssl enc -pbkdf2 -a` without a cipher, which only encodes the value as base64. Anyone who can read such a file can read the secret. nix-infra prints a warning that lists these files when it reads one. Run `nix-infra secrets migrate` (see below).

An OpenSSL file made with another cipher (for example AES-128) cannot be read. Decrypt it manually with `openssl enc -d -a -<cipher> [-pbkdf2] [-md <digest>] -in <file>` and store the value again.

`readSecret` returns the same value as earlier versions for every format (line breaks normalized to `\n`, the final line break removed), so deployed secrets do not change when a file is migrated.

## Migrating existing secrets

1. **Upgrade nix-infra on every computer that deploys** (and in CI) first. An older nix-infra cannot read v2 files and skips such a secret during deployment, so the node runs without it.
2. **Check the folder:**

   ```sh
   nix-infra secrets list
   nix-infra secrets migrate --dry-run
   ```

3. **Migrate:**

   ```sh
   nix-infra secrets migrate
   ```

   The command lists the files it will change (name, current format, action) and asks for confirmation (`--batch` skips the question). Each legacy file is decrypted (`SECRETS_PASS` is needed for OpenSSL files, and for all files to write v2), encrypted as v2 with `SECRETS_PASS`, and replaced atomically with mode 400. v2 files are not changed. No plaintext and no backup copy is written. A file that cannot be read is reported and left unchanged, and the command exits with code 1; fix it and run the command again.
4. **Rotate the secrets that were exposed.** If the `secrets/` folder was ever committed, copied or shared while it held base64 files, treat those values as public: change them at the source (database passwords, API tokens, ...), store the new values with `nix-infra secrets store --overwrite`, and deploy.

### Changing the files key

To move to a new key (for example from a password to a generated key):

```sh
nix-infra secrets new-key > new-key.txt   # the key on stdout, instructions on stderr
export NEW_SECRETS_PASS="$(cat new-key.txt)"
nix-infra secrets migrate --new-key-env NEW_SECRETS_PASS
```

`--new-key-env <VAR>` re-encrypts every file (v2 and legacy) from the key in `SECRETS_PASS` to the key in `<VAR>`. It refuses when the variable is missing, empty, equal to `SECRETS_PASS`, or starts with `nisk1_` but is not a valid generated key. Files that the new key already opens are skipped, so after a failure you can run the command again until it succeeds; keep both keys until then.

When it succeeds, store the new key as `SECRETS_PASS` (in `.env`, or in the sysops vault), remove `NEW_SECRETS_PASS` and delete `new-key.txt`. Every computer that deploys needs the new key.

## Listing secrets

```sh
nix-infra secrets list
```

Prints one line per file in `secrets/`: name, format (`v2`, `openssl`, `plain`, `unknown`, or `link` for a symbolic link, which is not followed), kind and created (v2 only), and the modification time. Names that start with `.` are ignored. No key is needed and nothing is decrypted.

## Generating a files key

```sh
nix-infra secrets new-key
```

Prints a new generated files key (`nisk1_...`) on stdout, once, and the instructions on stderr, so `nix-infra secrets new-key > key.txt` captures only the key. In a new project, store it as `SECRETS_PASS`. In a project that already has secret files, follow [Changing the files key](#changing-the-files-key).

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
   - Reads and decrypts the secret locally using `SECRETS_PASS`
   - Applies variable substitutions (node IPs, overlay IPs, etc.)
   - Deploys the secret encrypted via `systemd-creds encrypt` on the remote node to `/root/secrets/`
3. **Bootstrap netrc** — If any `secrets.netrc/` placeholders were found, nix-infra decrypts and combines them into `/run/keys/combined-netrc` (chmod 0400) on the remote machine via SSH. This happens before `nixos-rebuild` so that Nix can authenticate to private repos during the build.
4. **Garbage collect** — Any secrets on the remote node that are not in the expected list are removed

If a referenced secret doesn't exist in the local `secrets/` directory, the deployment prints a warning and continues. The warning includes instructions for creating the missing secret.

If a referenced secret exists but cannot be read (wrong key, damaged file, unknown format), the deployment prints `ERROR! Secret '<name>' could not be read: <reason>` (never the value) and stops for that node, before any secret is removed from the node. Earlier versions skipped such a secret silently.

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

- **Encryption at rest** — Secret files written by this version are `nix-infra-secret/v2` files: AES-256-GCM with the header as authenticated data (see [Encryption](#encryption)). Files written by earlier versions are base64 only until you run `nix-infra secrets migrate`
- **Encryption in transit** — Secrets are transmitted over SSH
- **Encryption at runtime** — Secrets are encrypted on the target with systemd-creds and only decrypted by the owning systemd service

- **File permissions** — All secret files are mode `0400` (owner read-only), the `secrets/` directory is mode `0700`
- **Atomic writes** — A secret file is written to a temporary file, read back and checked, then renamed into place; the value is never written to disk in plaintext
- **Not in version control** — Keep `secrets/` ignored in git (the project templates have `secrets/*` in `.gitignore`)
- **Garbage collection** — Unused secrets are automatically removed from target nodes during deployment
- **SECRETS_PASS isolation** — The files key is sourced from `.env`, the environment or an interactive prompt, never stored in configuration files

## Troubleshooting

**"Secret file 'name' not found"** — The secret hasn't been stored yet. Run `nix-infra secrets store --name="name" --secret="value"` to create it.

**"WARNING! Secret 'name' not found in secrets directory, skipping deployment"** — The node config references a secret that doesn't exist locally. The deployment continues but the secret won't be available on the node.

**"ERROR! Secret 'name' could not be read: ..."** — The secret file exists but cannot be decrypted: the key in `SECRETS_PASS` is wrong (a v2 file reports the `key_id` it expects), the file was modified or damaged, or the format is not known. The deployment of that node stops before anything is removed from `/root/secrets`. Earlier versions skipped such a secret silently. Check the key, run `nix-infra secrets list` to see the format of the file, and store the value again if the file is damaged.

**"ERROR! Secret "name" exists. Use --overwrite to replace it."** — `secrets store` and `--save-as-secret` do not replace an existing secret. Use `nix-infra secrets store --overwrite` to replace it.

**"WARNING! These secret files are not encrypted, run `nix-infra secrets migrate`"** — Some files are legacy base64 files. See [Migrating existing secrets](#migrating-existing-secrets).

**Wrong SECRETS_PASS** — A v2 file fails with a clear error (`SecretKeyMismatch` or `SecretDecryptFailed`), never with garbled output. Ensure `SECRETS_PASS` in your `.env` matches the key the secrets were stored with.

**"Cannot specify both --secret and --secret-file"** — The two options are mutually exclusive. Use `--secret` for inline values or `--secret-file` for file contents.