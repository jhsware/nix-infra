NOTE: This are pre 1.0 releases, this means there can be breaking changes on minor releases without clear warnings.

## Unreleased
- added `SSH_KEY_PATH=<private key file>` (in `.env` or the environment; the environment wins): every CLI command uses that file as the private key for every machine, in place of `ssh_key` of `servers.yaml` and `ssh/<SSH_KEY>`, with no fallback to another key. The path is absolute, relative to the project, or starts with `~/`; a file that does not exist stops the command before any connection. The MCP servers do not read it. See docs/ARCHITECTURE.md "SSH keys"
- with `SSH_KEY_PATH`, `SSH_KEY` / `--ssh-key` is optional for the commands that only connect (`cmd`, `ssh`, `upload`, `update`, `deploy-apps`, `init-machine`, ...); `provision` still needs the key name for the cloud provider
- the public key (root's authorized key `[%%sshKey%%]` and the key registered at Hetzner) is `<private key>.pub` when it exists, else derived from the private key
- a failed SSH authentication with `SSH_KEY_PATH` set says that the machine does not accept the key of `SSH_KEY_PATH`; without it the text is unchanged
- BEHAVIOUR CHANGE: `ssh_key` of `servers.yaml` is now also used by the registry, certificate, secrets and provision steps, which built the path `ssh/<name>` from the key name before. This changes the key file for a node whose `ssh_key` is not `ssh/<name>`; the public key of such a node is now `<ssh_key>.pub` (or derived) instead of `ssh/<name>.pub`
- `ProviderFactory.autoDetect`, `SelfHosting.load` and `HetznerCloud` have an optional `sshKeyPath` parameter (default: no change); `ClusterNode` has `sshKeyPathFromEnv`. Removed `getSshKeyAsPem` (`lib/helpers.dart`), which had no caller left; use `getSshKeyAsPemFromNode` or `publicKeyOf` (`lib/ssh_key_path.dart`)
- a missing SSH key name (`SSH_KEY` / `--ssh-key`) is reported as `No SSH key configured. Set SSH_KEY in .env or the environment, pass --ssh-key=<name>, or set SSH_KEY_PATH=<private key file>.` (`provision`: `... or pass --ssh-key=<name>. This command gives the key name to the cloud provider, so SSH_KEY_PATH alone is not enough.`) and the command exits with code 1; earlier versions failed with `type 'Null' is not a subtype of type 'String'` (`provision`: `Null check operator used on a null value`). An empty `--ssh-key` or `SSH_KEY` counts as not set
- `registry list-images` works again: it read a `--batch` flag that it does not declare, so every call stopped with a usage error (exit 64). It no longer asks for confirmation (it asked "Are you sure you want to publish this image?")
- `cluster -d`, `--ssh-key` and `--env` now reach the `cluster etcd ...` commands; before, they were ignored and the command ran in `.` without the key. An option given to `etcd` or after the subcommand name still wins
- upgraded dartssh2 from 2.14 to 4.1 (key files work as before): SHA-1 key exchange, the `ssh-rsa` host key signature and CBC ciphers are no longer offered. A current OpenSSH (as on NixOS) is not affected; an old SSH server may refuse the connection, and the error then names the failed handshake (for example `No matching key exchange algorithm`) instead of a failed authentication. `--ssh-timeout` of the MCP servers now also bounds the SSH handshake and the login, not only the TCP connect, and also applies to the MCP tool `etcd`. SSH and SFTP connections are now closed, and waited for, when their work ends (`upload` and the MCP tool `file-upload` also after an error); `port-forward` closes its connection when it is stopped (Ctrl-C) or when the SSH connection ends

## 0.18.0-beta
- SECURITY: secret files made by earlier versions are NOT encrypted. `secrets store` and `--save-as-secret` ran `openssl enc -pbkdf2 -a` without a cipher, which only encodes the value as base64, and the documentation wrongly said the files were encrypted and safe for version control. Upgrade nix-infra on every computer that deploys, run `nix-infra secrets migrate`, and rotate the secrets if the `secrets/` folder was ever committed, copied or shared. Keep `secrets/` ignored in git. See docs/SECRETS.md "Migrating existing secrets"
- secrets are now written as `nix-infra-secret/v2` files: AES-256-GCM with an authenticated header, encrypted in-process (no openssl child process, the value never on a command line or on disk in plaintext), atomic write with a read-back check, mode 400
- `SECRETS_PASS` can be a generated files key (`nisk1_...`, HKDF-SHA256, recommended) or a password (PBKDF2-HMAC-SHA256, 600000 iterations, about 2.4 s per derivation)
- legacy files are still read: base64 (with a warning that lists them) and OpenSSL `Salted__` AES-256-CBC files (PBKDF2, EVP_BytesToKey SHA-256 or MD5); deployed values are byte-for-byte the same as before
- BREAKING: a secret that exists but cannot be read (wrong key, damaged file, unknown format) now stops the deployment of the node with `ERROR! Secret '<name>' could not be read: <reason>`; earlier versions skipped it silently
- BREAKING: `secrets store` and `--save-as-secret` no longer replace an existing secret; use `secrets store --overwrite`
- BREAKING: a variable set in the process environment now wins over the same name in `.env` (before, `.env` won). This applies to every command, the MCP servers, `init` and `cert`. An empty variable does not hide a `.env` value. If you export a variable (for example `HCLOUD_TOKEN` or `SECRETS_PASS` for another project) and relied on `.env` to replace it, unset it. A wrapper script that sources `.env` still replaces exported values before nix-infra starts. See docs/SECRETS.md "The key (SECRETS_PASS)" and docs/ARCHITECTURE.md "Configuration and `.env`"
- `loadEnv` has an optional `processEnvironment` parameter, and the new `envWithProcessPrecedence` (`lib/helpers.dart`) builds the env for library callers
- added `nix-infra secrets migrate` (`--dry-run`, `--batch`) to encrypt legacy files as v2, and `--new-key-env <VAR>` to re-encrypt all files with a new key (can be run again after a failure)
- added `nix-infra secrets list` (name, format, kind, created, modified; no key needed)
- added `nix-infra secrets new-key` to print a generated files key
- the netrc bootstrap writes a line break after each decrypted entry, so two netrc secrets no longer join on one line
- an older nix-infra cannot read v2 files and skips them during deployment: upgrade every computer that deploys before storing or migrating secrets
- `provision --debug --batch` now exits with code 3 after the install because the nodes are not rebooted; this stops chained scripts from running later steps against the old OS
- `provision --debug` now pauses after the install so you can reboot the nodes manually, then runs the conversion check once (no retries); with `--batch` the check is skipped
- the install script now runs `switch-to-configuration boot` with `NIXOS_INSTALL_BOOTLOADER=1`, so the bootloader is reinstalled on every run; a retried install wipes the ESP and previously left it without an EFI boot file
- on EFI nodes the install verifies that an EFI boot file exists under `/boot` after the bootloader step, `NIX_INFRA_FAIL` otherwise
- `provision --debug` no longer runs the conversion check and retry loop; the nodes are not rebooted in debug mode, so the check always saw the old OS and the retries destroyed a good install
- `--debug` is now a global option on the root command (`nix-infra --debug cluster provision ...`); the group-level flag still works as an alias
- hardened the provision install script: every step must succeed (nixos-infect, configuration.nix install, system profile, bootloader install, GRUB menu check); on failure the node is NOT rebooted and stays reachable over SSH, and the output contains a `NIX_INFRA_FAIL <node>: <reason>` line
- the install now prints node boot facts as `NIX_INFRA_FACT` lines (boot_mode EFI/BIOS, disks, efibootmgr entries), visible also without `--debug`
- synced jhsware/nixos-infect with upstream elitak/nixos-infect (EFI sysmount support, non-EFI fixes, default channel 25.11)
- nixos-infect PROVIDER is now passed explicitly per node because upstream removed working autodetection; servers.yaml is the source of truth (`provider: hetzner` gets `PROVIDER=hetznercloud`, static `ip` gets none), servers listed by the Hetzner Cloud provider always get `PROVIDER=hetznercloud`
- removed the unused `--provider` option on `provision`; the provider is auto-detected and servers.yaml cannot be overridden
- added optional `vpn` parameter per server in servers.yaml (name of VPN connection required to reach the server), exposed by the MCP list-available-nodes tool and in SSH connection error hints so agents can ask the user to start the VPN
- MCP tools now use a 10s SSH connect timeout by default (fail fast when a server is unreachable); override with --ssh-timeout=<seconds> on poor connections

## 0.17.0-beta
- added support for converting RHEL-based servers to NixOS (self hosting)
- fixed bug in ascii progress bar that made it wander to the bottom of the screen
- removed static reference to .env

## 0.16.0-beta
- BREAKING: removed legacy commands
- added support for self hosting by configuring server.yaml file
- stability improvements
- documentation improvements
- clean up
- improved test coverage
- fixed test runner, test environment support for MCP tool
- added building linux binaries for MCPs (experimental)

## 0.15.0-beta
- improve MCP tools and docs

## 0.14.0-alpha
- improve safety guards for MCP tools

## 0.13.0-alpha
- split mcp sysops tool into cluster and machine

## 0.12.1-alpha
- fix NixOS upgrade command
- added an experimental MCP test runner (WIP)
- added filesystem access and initial safety guards to MCP tools

## 0.11.0-alpha
- BREAKING: new cli command structure with separate cluster and fleet operations

## 0.10.0-alpha
- added support of forming a fleet of standalone machines

## 0.9.6-alpha
- support placement groups to remove single point of failure due nodes being on the same physical machine

## 0.9.5-alpha
- more robust conversion to NixOS with retry

## 0.9.4-alpha
- improve secrets handling

## 0.9.2-alpha
- improving cluster formation

## 0.9.1-alpha
- added workflow to generate linux binary for releases

## 0.9.0-alpha
- first release, macOS only