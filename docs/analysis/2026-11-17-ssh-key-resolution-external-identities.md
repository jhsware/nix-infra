# SSH key resolution and keys held by a caller (sysops vault) — analysis

**Date:** 2026-11-17
**Status:** Implemented on 2026-11-17: §5.1 in branch `fix/ssh-key-name-missing-error`, §5.2 to §5.7 in branch `feat/ssh-key-path` (commits `1684f65`, `318612c`, `bb9c6b1`, `ffc5f9c`, `79a3dc0`, and the docs commit). Two deviations from this note, marked where they apply: the providers carry `sshKeyPath` instead of a wrapper provider (§5.3), and the message of `provision` (§5.1). §4 to §6 were revised on 2026-11-17 after the decisions of the operator (no key of the vault for MCP servers; `SSH_KEY_PATH` in place of a JSON manifest; one key per sysops terminal, chosen at its creation). **Removed again on 2026-11-18:** §5.2 to §5.7 (`SSH_KEY_PATH`) were removed with no transition by `docs/design/ssh_agent_keys.md` §8 (accepted 2026-11-18 on branch `docs/mcp-ssh-key-config`; removal in branch `chore/remove-ssh-key-path`); keys held outside the project now come from an `ssh-agent` with a key map. §5.1 (the clear error for a missing key name) stays; its text no longer offers `SSH_KEY_PATH`. The public key from `<private key>.pub` or derived, and `ssh_key` of `servers.yaml` at every key site, also stay. The design was implemented on 2026-11-18 (its §15 says what was built in another way).
**Code reviewed:** nix-infra `bf872e2` (main, 0.18.0-beta), dartssh2 2.14.0 (locked) and 2.22.0, sysops_server `cf2c8f5`.
**Companion note:** `sysops_server/docs/analysis/2026-11-17-vault-ssh-keys-nix-infra.md` (the sysops side: terminals, agent sessions, security review).

---

## 1. Summary

Reported from a sysops terminal, in a project whose `.env` has no `SSH_KEY` because the private key is in the sysops vault:

```
$ ./cli update urbantalk001
nix-infra command: dart run --verbosity=error ../nix-infra/bin/nix_infra.dart
- ERROR: type 'Null' is not a subtype of type 'String'
- ERROR: type 'Null' is not a subtype of type 'String'
- ERROR: type 'Null' is not a subtype of type 'String'
```

Two problems in nix-infra:

1. **A missing key name crashes with a type error.** 28 command lines assign a possibly-null value to a `String`. `./cli update` runs `fleet update`, `fleet deploy-apps` and `fleet cmd`; each one fails on that line.
2. **A key can only come from a file that nix-infra finds by name.** There is no way for a caller that holds the key somewhere else (sysops keeps it encrypted in a vault and decrypts it to a private runtime folder) to tell nix-infra which key file to use for which machine. An `ssh-agent` does not help: nix-infra cannot authenticate through one, and it also needs the public key.

Proposal (revised, §5): (a) one helper that reads the key name and fails with a clear message; (b) a new setting `SSH_KEY_PATH`, the path of a private key file that the CLI uses for every machine in place of `<project>/ssh/<SSH_KEY>`. With `SSH_KEY_PATH`, `SSH_KEY` is optional for commands that only connect, and the public key is derived from the private key. A project without `SSH_KEY_PATH` behaves as today.

---

## 2. Reproduction

```
$ env -u SSH_KEY dart run --verbosity=error bin/nix_infra.dart fleet cmd -d <empty dir> --target=x uptime
- ERROR: type 'Null' is not a subtype of type 'String'

$ env SSH_KEY=x dart run --verbosity=error bin/nix_infra.dart fleet cmd -d <empty dir> --target=x uptime
- ERROR: No provider configuration found. Either: …      (past the key name; a later, correct error)

$ env -u SSH_KEY dart run --verbosity=error bin/nix_infra_machine_mcp.dart --project-dir=<empty dir>
ERROR! env-var SSH_KEY is missing                          (exit 2)
```

Dart 3.11.6, 2026-11-17. At the time of this reproduction the proposal of §5 was not implemented (see Status).

---

## 3. How a key is resolved today

### 3.1 The key name

```dart
// bin/commands/machine.dart:117 (fleet update); the same line at :66, :163, :212, :264,
// bin/commands/shared.dart:184, 228, 316, 353, 390, 475, 522,
// and in cluster.dart (8), etcd.dart (6), registry.dart (2)
final String sshKeyName = parent?.argResults!['ssh-key'] ?? env['SSH_KEY'];
```

- `parent?.argResults!['ssh-key']` is `dynamic`, so the whole expression is `dynamic` and the compiler accepts the assignment. At run time a null value throws `TypeError`.
- `bin/commands/shared.dart:56` (`provision`) uses `env['SSH_KEY']!` and fails with "Null check operator used on a null value" instead. `bin/commands/init.dart:82` is the only command that handles the case (`?? readInput(...)`).
- `TypeError` is an `Error`. `main` (`bin/nix_infra.dart:32-43`) prints `ERROR: ${err}` and exits 1. No hint of `SSH_KEY`.
- The three MCP servers check for null and print `ERROR! env-var SSH_KEY is missing` (`bin/nix_infra_machine_mcp.dart:48-53`, the same in the cluster and dev servers).
- The wrapper script of a fleet project has `SSH_KEY=${SSH_KEY:-"nixinfra-machine"}`. That is a shell variable of the script; it is not exported and `update`, `deploy-apps` and `cmd` do not pass `--ssh-key`, so nix-infra does not see the default.

The name flows on: `getProvider(workingDir, env, sshKeyName)` → `ProviderFactory.autoDetect` → `HetznerCloud(sshKey:)`, which sets `ClusterNode.sshKeyName` for every server (`lib/providers/hcloud.dart:133`). The self-hosting provider takes the name from the last part of the `ssh_key` path of `servers.yaml` and sets `ClusterNode.sshKeyPath` (`lib/providers/self_hosting.dart:242-269`).

### 3.2 The key files

`ClusterNode.getEffectiveSshKeyPath` (`lib/types.dart:53`): `sshKeyPath` when set (absolute, or relative to the project), else `<project>/ssh/<sshKeyName>`.

| Use | Call sites | Path used |
|---|---|---|
| Private key, dartssh2 (`SSHKeyPair.fromPem`) | `getSshKeyAsPemFromNode` (`lib/helpers.dart:172`) from `lib/ssh.dart:41, 266, 307`; through `getSshClient` and `runCommandOverSsh` this covers deploy, update, cmd, action, upload, port-forward and all MCP tools | `getEffectiveSshKeyPath` |
| Private key, dartssh2 | `lib/certificates.dart:353` | `<project>/ssh/<sshKeyName>` (ignores `sshKeyPath`) |
| Private key, `ssh -i` child process | `lib/provision.dart:276, 312, 324, 385`; `lib/docker_registry.dart:33, 82`; `lib/secrets.dart:555` | `<project>/ssh/<sshKeyName>` (ignores `sshKeyPath`) |
| Public key → `[%%sshKey%%]` in `configuration.nix` (authorized key of root) | `lib/cluster_node.dart:118, 205`; `lib/provision.dart:199`; `lib/control_node.dart:14`; `bin/commands/shared.dart:250` | `<project>/ssh/<sshKeyName>.pub` |
| Public key → Hetzner `ssh_keys` (provision, `ssh-key add`) | `lib/providers/hcloud.dart:220` | `<project>/ssh/<keyName>.pub` |

Observations:

- `fleet update` and `init-machine` read the **public** key (`deployMachine`, `lib/cluster_node.dart:118`) before they connect.
- Eight private key sites and all public key sites build the path from the name and ignore `sshKeyPath`. For a `servers.yaml` node whose `ssh_key` is outside `<project>/ssh/`, these sites already use the wrong file today.

### 3.3 No `ssh-agent`

All authentication is `SSHClient(identities: SSHKeyPair.fromPem(<text of the file>))`.

- dartssh2 2.14.0 (in `pubspec.lock`) has no agent code.
- dartssh2 2.22.0 adds agent *forwarding* (`SSHAgentHandler`, `SSHKeyPairAgent`: the client answers agent requests of the remote side from keys it holds in memory). It has no client for a local agent socket.
- `SSHKeyPair.sign(Uint8List)` is synchronous and `SSHClient` calls it inline when it builds the user-auth request. A key pair that signs through `SSH_AUTH_SOCK` needs an asynchronous sign, so it needs a change of dartssh2.

So `SSH_AUTH_SOCK` in the environment has no effect on nix-infra. Only the `ssh -i` child processes of the table would fall back to an agent, and only when the `-i` file is missing.

---

## 4. What the caller (sysops) can offer

sysops stores the private key of a project encrypted, selects a key per machine name (exact name, wildcard, default key) and writes the selected key to `<dataDir>/run/ssh-keys/<projectId>/<keyId>-<fp>` (mode 600, outside the project folder) for its own `ssh -i` calls. A local terminal of sysops gets the keys through a per-terminal `ssh-agent`. It gets no `SSH_KEY`, no file in `<project>/ssh/` and no public key file. An agent session that starts `nix-infra-machine-mcp` gets nothing, and by the decision of the operator (2026-11-17) that stays so: an MCP server does not get a key of the sysops vault.

Constraints for a contract:

- sysops can select a different key per machine, but the operator wants one key per terminal (decision of 2026-11-17): the key is chosen when the terminal is created, the default key of the vault is the default, and a terminal must not reach the machines of another key. nix-infra itself has one key name per cloud project. So the contract carries one key.
- sysops also uses nix-infra as a library (`ProviderFactory.autoDetect`, `ClusterNode.getEffectiveSshKeyPath`, `loadEnv`, `secret_codec.dart`; path dependency in its `pubspec.lock`). The contract must not change the behaviour of those calls.
- A key of the vault can be locked while a terminal is open. sysops then deletes the key file, so nix-infra must report a missing file clearly.

---

## 5. Proposal

Revised on 2026-11-17. The first version of this note proposed a JSON identity manifest (`NIX_INFRA_SSH_IDENTITIES`). It is replaced by one variable, `SSH_KEY_PATH`; §5.5 says why.

### 5.1 A clear error for a missing key name (small, independent)

One helper in `bin/commands/utils.dart` replaces the 28 lines and the `!` of `provision`:

```dart
/// --ssh-key, else SSH_KEY. Without both: '' when SSH_KEY_PATH is set and
/// the command only connects, else a readable Exception.
String resolveSshKeyName(ArgResults? parentArgs, DotEnv env, {bool requireName = false});
```

Message: `No SSH key configured. Set SSH_KEY in .env or the environment, pass --ssh-key=<name>, or set SSH_KEY_PATH=<private key file>.` It is thrown as an `Exception`, so `main` prints it as `ERROR: …`. `provision`, `init` and the `ssh-key` commands pass `requireName: true`: they give the name to the cloud provider.

As implemented: only `provision` calls the helper with `requireName: true` (`init` and `ssh-key` read their names themselves). Its message does not offer `SSH_KEY_PATH`, which cannot replace the name there: `No SSH key configured. Set SSH_KEY in .env or the environment, or pass --ssh-key=<name>. This command gives the key name to the cloud provider, so SSH_KEY_PATH alone is not enough.`

### 5.2 `SSH_KEY_PATH`

- Read from the same `env` as the other settings (`loadEnv`: `.env`, and a non-empty variable of the process environment wins).
- The path of a private key file: absolute, or relative to the project (the rule of `ssh_key` in `servers.yaml`). A leading `~/` is replaced by the home directory, because a value in `.env` is not expanded by a shell.
- When it is set and not empty, that file is the private key for **every** machine of the command. It wins over `ssh_key` of `servers.yaml` and over `<project>/ssh/<SSH_KEY>`. There is no fallback to another key: a machine that does not accept this key refuses the connection. That is wanted. sysops sets the variable to the one key that the operator chose for the terminal, and the machines of another key must stay out of reach of that terminal.
- A file that does not exist is an error before any connection: `SSH_KEY_PATH names a file that does not exist: <path>. If a sysops terminal set it: unlock the vault and open a new terminal.`
- A failed authentication with `SSH_KEY_PATH` set says so. Today's text is "SSH authentication failed - check SSH key permissions and configuration" (`lib/ssh.dart:63-67`). With the variable: `… the machine does not accept the key of SSH_KEY_PATH. It may belong to another SSH key (in sysops: open a terminal with the key of this machine).`
- The public key of a machine: `<private key path>.pub` when it exists, else derived from the private key: `<type> <base64 of the public key blob>`, where the blob is `SSHKeyPair.toPublicKey().encode()` and `<type>` is the first string of the blob. Do not use `SSHKeyPair.type` for the text: for an RSA key dartssh2 returns the signature algorithm there (`SSHRsaSignatureType.sha256`), not `ssh-rsa`. sysops derives the line the same way (`parseSshPrivateKey`).
- The path can be printed in an error. The key text never.

### 5.3 Where it goes in the code

- **Key name:** `resolveSshKeyName` (§5.1) in every command.
- **Key path, carried by the providers (as implemented; the first version of this note proposed a wrapper):** `getProvider()` (`bin/commands/shared.dart`) resolves `SSH_KEY_PATH` and passes it to `ProviderFactory.autoDetect(sshKeyPath:)`, which gives it to `SelfHosting.load(sshKeyPath:)` and to every `HetznerCloud(sshKeyPath:)` it builds. The providers set `node.sshKeyPath` (and `node.sshKeyPathFromEnv`, for the error text) on every node they list, so every `getSshKeyAsPemFromNode` call site works unchanged. The parameter defaults to null, so library users that omit it (sysops host discovery, the MCP servers) are not affected. A wrapper provider in `getProvider()` was not used: `lib/provision.dart` checks `provider is HetznerCloud` (placement groups in `createNodes`, the nixos-infect `PROVIDER` in `installNixos`, `waitForServers`), and a wrapper would fail those checks.
- **The eight private key sites that build `ssh/<name>`** (`provision.dart` ×4, `docker_registry.dart` ×2, `secrets.dart`, `certificates.dart`) use `node.getEffectiveSshKeyPath(workingDir.path)`. This also corrects the `servers.yaml` inconsistency of §3.2.
- **The five public key sites** call one new function, `publicKeyOf(workingDir, node)` (§5.2).
- **`HetznerCloud`:** accepts an empty key name for listing servers. `addSshKeyToCloudProvider` gets the public key in the same way (file, else derived from `SSH_KEY_PATH`), so that provisioning does not need `ssh/<name>.pub`. `createServer` still needs a real name.
- **MCP servers (`nix-infra-*-mcp`):** not changed in this proposal. They require `SSH_KEY` and read `<project>/ssh/<SSH_KEY>` as today (open question 2).

### 5.4 Behaviour that does not change, and provisioning

- No `SSH_KEY_PATH`: every command resolves keys as in 0.18, except that a missing name gives the message of §5.1 and the eight sites honour `ssh_key` of `servers.yaml`.
- `init` and `ssh-key create/add/remove` work with names and files in `<project>/ssh/` as before.

Provisioning and the `ssh-agent`. `installNixos` reads `ssh/<name>.pub` (`lib/provision.dart:199`) and opens a dartssh2 connection with the private key file to upload `install.sh` and `configuration.nix` (`:203`) **before** it starts the `ssh -i ssh/<name>` child processes (`:276`, `:312`). Only those child processes can use an agent (OpenSSH warns about a missing `-i` file and tries the agent). So an agent alone does not make `provision` work without the two files; today it works because the files are there. With `SSH_KEY_PATH` every step has its key. The key **name** for the cloud provider must still be given (`--ssh-key` or `SSH_KEY`); it can stay in `.env` as a name with no file. (Read from the code. Not run: a run creates a server.)

### 5.5 Alternatives that are not proposed

| Alternative | Why not |
|---|---|
| An identity manifest: `NIX_INFRA_SSH_IDENTITIES=<JSON file>` with a key file per machine, a default, and an `unavailable` reason (the first version of this note) | Its benefits: the keys of all machines in one terminal; a clear "this key is locked" in place of "file missing"; a long-running MCP server sees a rewritten file. Its costs: a file format, a resolver, and a file per terminal that the caller must write, protect and delete. MCP servers are out of scope, and the operator wants one key per terminal: it limits the machines that a terminal can reach. So no benefit is left. |
| Authenticate through `SSH_AUTH_SOCK` | Needs a change of dartssh2 (§3.3). `fleet update` still needs the public key, and with several keys in the agent nix-infra cannot know which public key belongs to which machine before it connects. It keeps the key unreadable for the process, so it is the way to go if an MCP server must ever use a key that it may not read. |
| Replace dartssh2 by the system `ssh` and `sftp` | A rewrite of every connection path: the SFTP uploads with substitution, port forwarding and the MCP tools. |
| The key text in an environment variable | The key would be visible in `env` and in the stored output of the terminal. |
| The caller writes the key to `<project>/ssh/<name>` | A plaintext key in the project folder is what a vault removes. |

### 5.6 Tests

- Unit: `resolveSshKeyName` (option, variable, `SSH_KEY_PATH` only, nothing, `requireName`); the path rules of §5.2 (absolute, relative, `~/`, missing file); the providers set `sshKeyPath` on every node and only with `SSH_KEY_PATH` (implemented: §5.3 has no wrapper).
- Public key derivation equals `ssh-keygen -y -f <file>` (without the comment) for RSA, ed25519 and ECDSA nistp256 test keys. (Implemented with keys that `ssh-keygen` makes in a temporary folder for each test run, so no private key is committed; `test/ssh_key_path_test.dart`.)
- CLI regression tests in the style of the `SECRETS_PASS` precedence test: no key name → the message of §5.1, exit 1; `SSH_KEY_PATH` and no `SSH_KEY` → `fleet cmd` gets past key resolution; `SSH_KEY_PATH` wins over `ssh/<SSH_KEY>`.
- The authentication error of §5.2 names `SSH_KEY_PATH` when it is set, and has the old text when it is not.

### 5.7 Release notes to write

- New: `SSH_KEY_PATH`. With it, `SSH_KEY` is optional for commands that only connect.
- A missing key name is reported in words.
- `ssh_key` of `servers.yaml` is now used by the registry, certificate, secrets and provision steps that built the path from the name before (a behaviour change for a node whose `ssh_key` is not `ssh/<name>`).
- The public key is derived from the private key when the `.pub` file is missing.

---

## 6. Open questions

1. Is the behaviour change for the eight `ssh/<name>` sites acceptable in 0.19?
2. Should the MCP servers read `SSH_KEY_PATH` too? This note leaves them unchanged. sysops never sets the variable for an agent session in either case, so the question is only about a person who sets it in `.env`.
3. The wrapper script of the fleet projects (`cli`) does not stop after a failed step of `update` and exits 0. Decision of the operator: left as it is for now; recorded as backlog item `18acb4ca-fda1-4599-8676-bdc41e17e5cc` in sysops_server.
