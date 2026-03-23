# Building Packages from Private Repositories

This guide explains how to build Nix packages that fetch source code from private GitHub (or GitLab) repositories. It covers the architecture, common pitfalls, and step-by-step setup.

## Background

NixOS packages sometimes need to fetch source code from private repositories. In a standard Nix setup this is straightforward with public repos, but private repos require authentication during the Nix build process. This is complicated by the fact that Nix builds happen inside a sandbox with limited access to the host system.

## The Correct Approach: `builtins.fetchTarball` + netrc

The recommended approach uses `builtins.fetchTarball` with the GitHub API tarball endpoint, authenticated via a netrc file that the Nix daemon reads automatically.

### How it works

```nix
# In package.nix:
src = builtins.fetchTarball {
  url = "https://api.github.com/repos/OWNER/REPO/tarball/COMMIT_OR_REF";
  sha256 = "...";
};
```

1. The Nix daemon's built-in HTTP client sends a GET request to `api.github.com`
2. The daemon reads credentials from `nix.settings.netrc-file` and includes them in the request
3. GitHub returns a 302 redirect to a signed `codeload.github.com` URL
4. Nix follows the redirect, downloads the tarball, unpacks it, and strips the top-level directory
5. The `sha256` makes this a pure, reproducible fixed-output derivation

### Why this works

`builtins.fetchTarball` is a Nix built-in that runs inside the Nix daemon process itself (not inside the build sandbox). The daemon has access to its own configuration, including `nix.settings.netrc-file`, so it can authenticate HTTPS requests.

## Approaches That Do NOT Work

### `fetchFromGitHub` (default mode)

```nix
# DOES NOT WORK for private repos
src = fetchFromGitHub {
  owner = "OWNER";
  repo = "REPO";
  rev = "COMMIT";
  sha256 = "...";
};
```

`fetchFromGitHub` in its default mode constructs a GitHub archive URL (`github.com/OWNER/REPO/archive/REF.tar.gz`). For private repositories, this URL returns **404** because GitHub requires authentication for archive downloads from private repos, and `fetchFromGitHub` does not pass netrc credentials.

### `fetchFromGitHub` with `forceFetchGit = true`

```nix
# DOES NOT WORK for private repos
src = fetchFromGitHub {
  owner = "OWNER";
  repo = "REPO";
  rev = "COMMIT";
  sha256 = "...";
  forceFetchGit = true;
};
```

Setting `forceFetchGit = true` makes `fetchFromGitHub` run `git clone` instead of downloading an archive. However, `git clone` runs **inside the Nix build sandbox**, which is an isolated environment. The sandbox cannot access `/run/keys/combined-netrc` or any other host files. This means git has no credentials and the clone fails with authentication errors.

This is a fundamental limitation: the Nix sandbox isolates builds from the host filesystem for reproducibility. There is no way to pass netrc or SSH keys into the sandbox without breaking the security model.

### SSH deploy keys

SSH deploy keys have the same problem as `forceFetchGit` — the SSH agent and key files are not accessible from inside the Nix build sandbox. Additionally, SSH keys add operational complexity (key rotation, per-repo keys, etc.).

## Netrc Machine Hostname Matching

**This is the most common pitfall.** The `machine` field in the netrc file must **exactly match** the hostname in the URL being fetched.

Since `builtins.fetchTarball` fetches from `api.github.com`, the netrc must use:

```
machine api.github.com
login x-access-token
password ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Using `machine github.com` will **NOT** work — the Nix daemon will not match the credential against `api.github.com` requests, and GitHub will return HTTP 404 (not 403) for unauthenticated requests to private repo endpoints.

## Architecture Overview

### Build-time credential flow

```
nix.settings.netrc-file = "/run/keys/combined-netrc"
         |
         v
   Nix daemon reads netrc
         |
         v
   builtins.fetchTarball sends GET to api.github.com
         |
         v
   GitHub authenticates via netrc credentials
         |
         v
   302 redirect to signed codeload.github.com URL
         |
         v
   Nix downloads tarball, verifies sha256, unpacks
```

### Credential lifecycle on the server

The netrc file at `/run/keys/combined-netrc` is on tmpfs and disappears on reboot. It is created by two complementary mechanisms:

1. **Bootstrap (first deploy):** nix-infra detects `secrets.netrc/` patterns in node configs and decrypts the netrc secrets to `/run/keys/combined-netrc` **before** running `nixos-rebuild switch`. This solves the chicken-and-egg problem where the NixOS module's systemd service doesn't exist yet.

2. **Reboot (steady state):** A systemd oneshot service (configured in the app module) uses `LoadCredentialEncrypted` to decrypt the netrc secret and write it to `/run/keys/combined-netrc` before `nix-daemon.service` starts.

Both mechanisms produce the same result: a netrc file at `/run/keys/combined-netrc` that the Nix daemon can read.

## Step-by-Step Setup

### 1. Create the package.nix

```nix
{
  lib,
  buildDartApplication,  # or whatever builder you need
  version ? "abc1234",   # default commit hash
}:

let
  versionHashes = {
    "abc1234" = {
      hash = "sha256:0000000000000000000000000000000000000000000000000000";
    };
  };

  versionInfo = versionHashes.${version} or (throw ''
    Commit ${version} is not supported.
    Supported commits: ${builtins.concatStringsSep ", " (builtins.attrNames versionHashes)}

    To add support for commit ${version}:
    1. Add entry to versionHashes with a dummy hash
    2. Build and use the hash from the error message
  '');

  src = builtins.fetchTarball {
    url = "https://api.github.com/repos/OWNER/REPO/tarball/${version}";
    sha256 = versionInfo.hash;
  };

in
# ... your build derivation using src
```

### 2. Create the netrc file

Create a temporary file (do NOT commit it):

```
machine api.github.com
login x-access-token
password ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The token needs the `repo` scope (or fine-grained equivalent) to access private repository contents.

### 3. Store the netrc as an encrypted secret

```sh
nix-infra secrets store \
  --name="secrets.netrc/my-app-github-netrc" \
  --secret-file="./my-github-netrc"
```

The `secrets.netrc/` prefix is a naming convention that tells nix-infra this secret participates in the netrc bootstrap mechanism. Delete the temporary file after storing.

### 4. Configure the NixOS module (default.nix)

Your app module needs:

**a) An option for the netrc secret path:**

```nix
secrets.githubNetrc = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  description = ''
    Path to the encrypted netrc secret for private GitHub repository access.
    Use nix-infra substitution syntax: [%%secrets.netrc/my-app-github-netrc%%]

    The netrc file must contain:
      machine api.github.com
      login x-access-token
      password <GITHUB_PAT>
  '';
  default = null;
};
```

**b) A systemd oneshot service to decrypt netrc on reboot:**

```nix
systemd.services.my-app-netrc-setup = lib.mkIf (githubNetrcSecretName != null) {
  description = "Decrypt GitHub netrc credentials for Nix daemon";
  wantedBy = [ "multi-user.target" ];
  before = [ "nix-daemon.service" ];

  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    LoadCredentialEncrypted = [
      "${githubNetrcSecretName}:/root/secrets/${githubNetrcSecretName}"
    ];
  };

  script = ''
    set -euo pipefail
    mkdir -p /run/keys
    chmod 755 /run/keys
    NETRC_FILE="$CREDENTIALS_DIRECTORY/${githubNetrcSecretName}"
    if [ ! -f "$NETRC_FILE" ]; then
      echo "ERROR: Netrc secret not found at $NETRC_FILE"
      exit 1
    fi
    cat "$NETRC_FILE" >> /run/keys/combined-netrc
    chmod 0400 /run/keys/combined-netrc
  '';
};
```

**c) The nix daemon netrc-file setting:**

```nix
nix.settings.netrc-file = "/run/keys/combined-netrc";
```

### 5. Reference the secret in the node configuration

```nix
# In nodes/mynode.nix:
infrastructure.my-app = {
  enable = true;
  secrets.githubNetrc = "[%%secrets.netrc/my-app-github-netrc%%]";
};
```

### 6. Deploy and get the correct hash

The first build will fail with a hash mismatch:

```
error: hash mismatch in file downloaded from '...':
  specified: sha256:0000000000000000000000000000000000000000000000000000
  got:       sha256:1w93q80jqszs79q133ypx9smgjmhds776bfzq3k8v07ixry350zn
```

Copy the `got:` hash and update `package.nix`:

```nix
"abc1234" = {
  hash = "sha256:1w93q80jqszs79q133ypx9smgjmhds776bfzq3k8v07ixry350zn";
};
```

Commit and redeploy. The build should now succeed.

### 7. Adding new versions

To pin to a new commit:

1. Add the commit hash to `versionHashes` with `lib.fakeHash` (or a dummy hash)
2. Update the `version` default or set it in the node config
3. Deploy — the build fails with the correct hash
4. Update the hash in `package.nix`
5. Commit and redeploy

## Troubleshooting

### HTTP 404 from api.github.com

**Cause:** The netrc `machine` field doesn't match the URL hostname, or the token lacks the `repo` scope.

**Check the netrc on the server:**
```sh
ssh root@server cat /run/keys/combined-netrc
```
Verify it says `machine api.github.com` (not `machine github.com`).

**Test the token manually:**
```sh
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ghp_xxx" \
  https://api.github.com/repos/OWNER/REPO/tarball/COMMIT
```
You should get `302` (redirect to download). `404` means bad token or wrong scope.

### Hash mismatch on first build

This is expected. Use `lib.fakeHash` as the initial hash, build, copy the correct hash from the error, update, and rebuild.

### Netrc not available during bootstrap (first deploy)

nix-infra automatically handles this: when it detects `secrets.netrc/` patterns in node configs, it decrypts them to `/run/keys/combined-netrc` and adds `netrc-file` to `nix.conf` before running `nixos-rebuild`. No manual intervention needed.

### Netrc disappears after reboot

This is expected — `/run/` is tmpfs. The systemd oneshot service recreates the netrc before `nix-daemon` starts. If the oneshot isn't configured, `nix-daemon` starts without credentials and builds requiring private repos will fail.

### Verify the full chain

```sh
# 1. Check the netrc file exists and has correct hostname
ssh root@server cat /run/keys/combined-netrc

# 2. Check nix.conf has the netrc-file setting
ssh root@server grep netrc /etc/nix/nix.conf

# 3. Check the oneshot service status
ssh root@server systemctl status my-app-netrc-setup
```

### Reading a stored secret locally

To verify what's stored in a secret without deploying:

```sh
nix-infra secrets read --name="secrets.netrc/my-app-github-netrc"
```

## Security Considerations

- The GitHub PAT should have minimal scopes — only `repo` (or fine-grained `contents:read`) for the specific repository
- The netrc file at `/run/keys/combined-netrc` is mode `0400` (root read-only) on tmpfs (never persisted to disk)
- Secrets are encrypted at rest in `secrets/` using OpenSSL PBKDF2
- Secrets are encrypted on the server using `systemd-creds encrypt` (tied to the machine's TPM or `/var/lib/systemd/credential.secret`)
- The plaintext netrc only exists in memory (tmpfs) at runtime

See [SECRETS.md](./SECRETS.md) for the full secrets management documentation and [SECURITY.md](./SECURITY.md) for the overall security model.
