# SSH keys from an ssh-agent — design

**Date:** 2026-11-17
**Status:** Accepted by the operator on 2026-11-18, with the decisions of §13. Not implemented.
**Code reviewed:** nix-infra `188897b` (`main`, 0.18.0-beta), dartssh2 2.14.0 (locked). dartssh2 4.1.0 from its changelog and API pages only.
**Companion design:** `sysops_server/docs/design/ssh_keys_through_agents.md` (how sysops fills the agents).
**Replaces:** the `SSH_KEY_PATH` feature (`docs/analysis/2026-11-17-ssh-key-resolution-external-identities.md`) and the proposal of `docs/analysis/2026-11-17-mcp-ssh-key-config.md`.

---

## 1. Summary

nix-infra reads a private key from a file today. This design adds a second way: the key stays in an `ssh-agent`, and nix-infra asks the agent to sign. nix-infra then never sees the private key.

- **dartssh2 goes from 2.14 to 4.1.** Since 3.0 an identity can sign through another process.
- **A key map says which key of the agent each machine uses.** It is a JSON file named by `SSH_KEY_MAP_PATH`. It holds fingerprints, no secret.
- **The classic way does not change.** `SSH_KEY`, `SSH_EMAIL`, `.env`, the files `ssh/<SSH_KEY>` and `ssh/<SSH_KEY>.pub`, and `ssh_key` in `servers.yaml` work as before.
- **`SSH_KEY_PATH` is removed, with no transition.** It was merged on 2026-11-17 and is in no released binary.

## 2. Goals and non-goals

**Goals**

1. A caller (sysops, or a person) gives nix-infra SSH keys without a private key file.
2. Different machines can use different keys.
3. The CLI and the three MCP servers behave the same.
4. A project that uses key files needs no change.
5. No text that an MCP tool returns holds a file path of a key, of the key map or of the agent socket.

**Non-goals**

- Checking host keys. nix-infra gives dartssh2 no `onVerifyHostKey` and runs `ssh` with `StrictHostKeyChecking=no` (`docs/SECURITY.md`, "StrictHostKeyChecking Disabled"). That stays a known gap; see §9.
- An agent on Windows (a named pipe). The agent mode is for Linux and macOS.
- Starting or filling an agent. The caller does that.
- Keys with a passphrase, hardware tokens, certificates. An agent that holds them may work; it is not tested.

## 3. The two key sources

Each machine gets its key from one of two sources. The key map decides.

| | Key file (as before) | Agent (new) |
|---|---|---|
| Chosen when | the key map does not name the machine, or there is no key map | the key map names the machine, or has a `default` |
| Private key | `ssh_key` of the machine in `servers.yaml`, else `ssh/<SSH_KEY>` | stays in the agent at `SSH_AUTH_SOCK` |
| Public key | `<key file>.pub`, else derived from the private key | the public key the agent lists |
| Key name `SSH_KEY` | required, except with `ssh_key` | not required to connect |

A developer's own agent is never used by accident: `SSH_AUTH_SOCK` alone changes nothing. Only a key map turns the agent on.

## 4. The inputs

All are read from the configuration, which is `.env` overlaid with the process environment (`lib/helpers.dart:296-322`).

| Name | Meaning | Change |
|---|---|---|
| `SSH_KEY` | The name of the key: the file `ssh/<name>`, and the name of the key at the cloud provider. | none |
| `SSH_EMAIL` | The comment of a key that `init` or `ssh-key create` makes. | none |
| `SSH_KEY_MAP_PATH` | The path of the key map (absolute, or relative to the project folder). | new |
| `SSH_AUTH_SOCK` | The socket of the agent. Used only for a machine that the key map gives an agent key. | new use |
| `SSH_KEY_PATH` | — | removed (§8) |

### 4.1 The key map

```json
{
  "version": 1,
  "default": { "agent_key": "SHA256:Yk0nDTpL0dQ4Jw0b4QnP3o1bq0oT1dS6r0Qe2m9uJ3c" },
  "nodes": {
    "web-1": { "agent_key": "SHA256:u2l0c8QfR1vN0mJ5rT8hD4kX9aYb3Wq7eZs6PpLo1Hg" },
    "db-1":  { "unavailable": "secrets_locked", "ring": "interactive" }
  }
}
```

- `version` is `1`. Another version is an error at the start.
- `default` and `nodes` are optional.
- An entry is `{"agent_key": <fingerprint>}` or `{"unavailable": <reason>}` with an optional `ring`. The fingerprint is the SHA-256 form that `ssh-add -l` prints.
- The name of a machine is `ClusterNode.name`, compared exactly.
- Unknown fields are ignored at every level.
- The file is read each time the list of machines is built (`getServers`), so the caller may replace it while an MCP server runs.
- There are no name patterns. The caller resolves the key of each machine.

### 4.2 The key of one machine

The first rule that names the machine decides:

1. `nodes[<name>]` of the key map;
2. `default` of the key map;
3. `ssh_key` of the machine in `servers.yaml`;
4. `ssh/<SSH_KEY>` in the project folder.

There is no fall-through after rule 1 or 2. An `unavailable` entry, an agent that cannot be reached, an agent that does not hold the key, and a key map that cannot be read are errors for that machine. A machine is never tried with another key than the one chosen for it.

## 5. The upgrade of dartssh2

`pubspec.yaml` goes from `dartssh2: ^2.12.0` to `^4.1.0`. dartssh2 4.1.0 needs Dart `>=3.0.0`; nix-infra needs `>=3.9.4`. No private import of dartssh2 exists in `lib/`, `bin/` or `test/`.

| Change in dartssh2 | Where it meets nix-infra | What to do |
|---|---|---|
| 3.0.0: `SSHClient.identities` is a list of `SSHIdentity` | four clients: `lib/ssh.dart:49, 282, 313`, `lib/certificates.dart:349` | source-compatible; all four move to one function (§6.2) |
| 3.0.0: `SSHClient.close()` returns a `Future`; 2.22.3: `SftpClient.close()` too | about 30 calls, none awaited (`lib/cluster_node.dart`, `lib/ssh.dart`, `bin/commands/shared.dart`, …); `portForward` never closes | await them; close the SFTP client before the SSH client |
| 3.1.0, 4.0.0: SHA-1 key exchange, the `ssh-rsa` host key signature and CBC ciphers leave the defaults | every connection | nothing for a current OpenSSH; test against a NixOS machine and a fresh Hetzner machine before `nixos-infect` |
| 4.0.0: a host key that changes during a rekey ends the connection | long connections (`ssh`, `action`, port forward) | nothing |
| 3.3.0: `SSHDisconnectError`, `SSHPacketError` | `runCommandOverSsh` maps errors by searching the text (`lib/ssh.dart:69-87`) | map by the type of the error where one exists |
| 2.22.0: `handshakeTimeout`, `authTimeout` | `--ssh-timeout` of the MCP servers bounds the TCP connect only | pass them, so a signature that never comes ends |

`nix-infra init` makes RSA keys of 2048 bits (`lib/ssh.dart:413-420`). RSA through an agent is therefore the normal case, not a corner case (§6.1).

## 6. The agent mode

### 6.1 The agent client

A new file `lib/ssh_agent.dart`. It speaks the SSH agent protocol (RFC 9987) over the Unix-domain socket of `SSH_AUTH_SOCK`. dartssh2 has no such client.

- Two requests: list the identities (`SSH_AGENTC_REQUEST_IDENTITIES`), and sign (`SSH_AGENTC_SIGN_REQUEST`).
- One short connection per request. A message larger than 256 KiB is refused.
- An identity of the agent becomes an `SSHIdentity.custom` of dartssh2: the public key is the blob the agent listed, and the signer sends the sign request.
- RSA: the sign request sets the flag for `rsa-sha2-512`, and the identity names that algorithm. Ed25519 and ECDSA need no flag.
- The agent says no (`SSH_AGENT_FAILURE`): the text of §7. The caller may have removed the key.

### 6.2 One place for "the key of a machine"

Today the key is read in four places for dartssh2, built into a command line in five places for `ssh`, and its public half is read in five more. The design puts each behind one function in a new file `lib/ssh_identity.dart`:

| Function | Replaces | Key file | Agent |
|---|---|---|---|
| `identitiesOf(workingDir, node)` | `SSHKeyPair.fromPem(await getSshKeyAsPemFromNode(...))` at `lib/ssh.dart:58, 285, 322`, `lib/certificates.dart:353` | reads the file, as today | the agent identity with the fingerprint of the machine |
| `publicKeyOf(workingDir, node)` | `lib/ssh_key_path.dart:102` (callers: `control_node.dart:15`, `cluster_node.dart:118, 204`, `provision.dart:199`, `shared.dart:257`) | `<file>.pub`, else derived | `<type> <base64 of the blob>` from the agent |
| `sshCommand(workingDir, node)` | the five `ssh -i "<file>" -o StrictHostKeyChecking=no root@<ip>` strings: `provision.dart:275, 311`, `docker_registry.dart:33, 82`, `secrets.dart:555` | the same string | `ssh -o IdentityAgent=<socket> -o IdentitiesOnly=yes -i <public key file>` |

For `ssh` with an agent, nix-infra writes the public key of the machine to a temporary file and deletes it after the command. `ssh` then offers that one key of the agent. A public key is not a secret.

A machine knows its source: `ClusterNode` gets a field for it (a key file, an agent key with its fingerprint, or unavailable with a reason). It is set where a node is built (`lib/providers/self_hosting.dart:270-280`, `lib/providers/hcloud.dart:149-153`), from a key map that `ProviderFactory.autoDetect` receives. `ClusterNode.sshKeyPath` stays for `ssh_key` of `servers.yaml`.

### 6.3 Commands

| Command or tool | Agent mode |
|---|---|
| Everything that connects: `fleet` and `cluster` commands, `etcd`, `registry`, `ssh`, `cmd`, `action`, `upload`; the MCP tools `remote-command`, `journalctl`, `systemctl`, `system-stats`, `cscli`, `etcd`, `file-upload` | works |
| `provision`, `ssh-key add` | work. They register the public key of the `default` entry at the cloud provider under the name `SSH_KEY`, so the name is required. |
| `init`, `ssh-key create` | make key files, as before. They do not put a key in an agent. |
| The dev MCP server (`test-runner`, `test-environment`) | starts shell scripts; they inherit the two variables. |

The three MCP servers stop requiring `SSH_KEY` when a key map is set (`bin/nix_infra_machine_mcp.dart:49-54` and the two others). The CLI does the same in `resolveSshKeyName` (`bin/commands/utils.dart:87-115`).

## 7. Texts

No tool result and no line on stderr of an MCP server holds the path of a key file, of the key map or of the agent socket. A text may name the machine, the variable and the fingerprint. (The documentation of Claude Code does not say where the stderr of an MCP server goes, so stderr gets the same rule.) The CLI may print paths: there they help the person at the terminal.

| Case | Text |
|---|---|
| `unavailable` entry | `The SSH key of machine "<name>" is not available (<reason>).` |
| The agent cannot be reached | `The SSH agent of this session cannot be reached. The key of machine "<name>" is not available.` |
| The agent does not hold the key, or refuses to sign | `The SSH agent does not hold the key of machine "<name>" (<fingerprint>). If sysops filled the agent: the vault may be locked.` |
| The machine refuses the key | `Machine "<name>" does not accept its key (<fingerprint>).` |
| A key map but no `SSH_AUTH_SOCK` | `SSH_KEY_MAP_PATH is set but SSH_AUTH_SOCK is not.` |
| A key file that does not exist (MCP) | `The SSH key file of machine "<name>" does not exist.` Today the path of the file is shown (`lib/ssh.dart:84-86`, `bin/mcp_server/file_upload.dart:126`). |

## 8. Removing `SSH_KEY_PATH`

| Remove | Where |
|---|---|
| `resolveSshKeyPath` and its only caller | `lib/ssh_key_path.dart:31-56`, `bin/commands/shared.dart:34` |
| The parameter `sshKeyPath` of the providers and of `autoDetect` | `lib/providers/provider_factory.dart:39, 60, 74, 89`, `self_hosting.dart:93-113, 168, 275-277`, `hcloud.dart:19-31, 146-153, 218-233` |
| `ClusterNode.sshKeyPathFromEnv` and its text | `lib/types.dart:35-38, 53`, `lib/ssh.dart:22-37` |
| The `SSH_KEY_PATH` branches of the key name | `bin/commands/utils.dart:79-84, 104-114` |
| Tests | `test/ssh_key_path_cli_test.dart`; the `SSH_KEY_PATH` groups of `test/ssh_key_path_test.dart`, `test/ssh_key_name_test.dart`, `test/providers_test.dart` |
| Documentation | every page that names `SSH_KEY_PATH`; the list is in §11.1 |

**Stays:** `ssh_key` of `servers.yaml` with `ClusterNode.sshKeyPath` and `getEffectiveSshKeyPath`; the public key functions of `lib/ssh_key_path.dart`; the clear error for a missing key name.

**No transition** (decision of the operator, 2026-11-18). After the removal nix-infra does not know the name. A set `SSH_KEY_PATH` has no effect and gives no error and no warning, as in every released nix-infra. sysops removes its guards for the name at the same time (companion design, §5).

For a caller that still sets the variable this means: nix-infra uses `ssh_key` of `servers.yaml` or `ssh/<SSH_KEY>` when there is one, else it stops with the error for a missing key name. It does not say that `SSH_KEY_PATH` was ignored.

## 9. Security boundaries

**What nix-infra guarantees in agent mode**

- It never reads, holds or writes a private key. It holds a socket path and public keys.
- It uses the agent only for a machine that the key map names. It never offers every key of the agent to a machine.
- It never falls back to another key after a failure.
- An MCP tool result never shows where the socket or the key map is.

**What it does not guarantee**

| Limit | Why |
|---|---|
| A process of the same UNIX user can use the agent while it runs. | The socket is a file of that user. The key cannot be copied out, but it can be asked to sign. |
| Whoever may call `remote-command` is root on the machine. | That is what the tool is for. Which machines a caller reaches is decided by the keys in its agent, so by the caller. |
| The machine at the other end is not checked. | No host key check (§2). An attacker in the network path cannot learn the key and cannot use the signature for another connection, but nix-infra would talk to the wrong machine and could send it files and secrets. |
| A key file of the classic way is as readable as before. | Unchanged. |
| A file tool of an agent session of sysops can read the key map and learn the path of the socket. | sysops sets no deny rules for the file tools (decision of the operator, §13). The key map holds fingerprints only, and a file tool cannot connect to a socket. |

**One change that belongs here.** The MCP tool `file-upload` uploads any local path the process can read (`bin/mcp_server/file_upload.dart:52-65`). It gets the limit that `configuration-files` has: local paths inside the project folder only. Without it an agent session can copy any file of the server user to a machine, whatever the key design is.

## 10. Tests

No test connects to an SSH server today.

| Test | What |
|---|---|
| Unit, always | The agent client against a fake agent (a Unix socket in the test): list, sign, refuse, a cut message, a message that is too large. The key map: every rule of §4. `identitiesOf`, `publicKeyOf`, `sshCommand` for both sources. |
| With `ssh-agent` and `ssh-add` on `PATH` (as the `ssh-keygen` tests do today) | A real agent with an Ed25519, an RSA and an ECDSA key: list them, sign, and check each signature with the public key. |
| With `sshd` on `PATH` | A local `sshd` on a free port with its own host key and one authorized key: `runCommandOverSsh` and an SFTP upload through the agent, with dartssh2 4.1. Also with a key file, to cover the upgrade. |
| By hand, before the release | One NixOS machine and one fresh Hetzner machine: `provision`, `fleet update`, `deploy-apps`, the MCP tools, each with a key file and with an agent. |

## 11. Order of work

1. **A trial, before anything else.** dartssh2 4.1, a first agent client, one login to a test machine through a real `ssh-agent` with an RSA key and an Ed25519 key. It answers the open points of §12. If RSA through `SSHIdentity.custom` does not work, the design stops here.
2. The upgrade of dartssh2 alone, with the classic way unchanged.
3. The agent client, the key map and the three functions of §6.2.
4. The removal of `SSH_KEY_PATH`.
5. The limit on `file-upload`.
6. The documentation that is left (§11.1). Most of it goes with steps 2 to 5.

Steps 2 and 5 are useful without the rest.

### 11.1 The documentation

Each change of the documentation goes with the code that it describes, so no page names a setting that the code does not have.

| File | Change | With step |
|---|---|---|
| `docs/ARCHITECTURE.md:61-85` (options, configuration, "SSH keys") | Write the section "SSH keys" again: the two key sources (§3), the key map (§4.1), the order of §4.2. Remove `SSH_KEY_PATH` from the option text (61), from the list of settings (67) and from the order (77-85). The sentence "dartssh2 has no `ssh-agent` client" goes. The MCP servers: `SSH_KEY` is not required with a key map. | 3, 4 |
| `docs/FLEET.md:76, 280` and `docs/CLUSTER.md:81, 448` | Remove the two `SSH_KEY_PATH` paragraphs of each file. In "Global Options", name `SSH_KEY_MAP_PATH` in one sentence with a link to "SSH keys". | 3, 4 |
| `docs/PROVIDERS.md:98` | The row `ssh_key`: remove the `SSH_KEY_PATH` sentence. Add that an entry of the key map wins over `ssh_key`. | 3, 4 |
| `docs/SECURITY.md:128` | Replace the `SSH_KEY_PATH` paragraph with the agent mode: what nix-infra guarantees and what it does not (§9). Add the limit of `file-upload`. "StrictHostKeyChecking Disabled" stays as it is. | 3, 4, 5 |
| `README.md:68` | Remove the `SSH_KEY_PATH` line. One line on keys from an `ssh-agent`, with a link. | 3, 4 |
| `CHANGELOG.md` (Unreleased) | Remove the `SSH_KEY_PATH` entry; it was never released. Add: dartssh2 4.1, keys from an `ssh-agent` with `SSH_KEY_MAP_PATH`, the limit of `file-upload`. | 2, 3, 4, 5 |
| `docs/analysis/2026-11-17-ssh-key-resolution-external-identities.md` | The status line: §5.2 to §5.7 (`SSH_KEY_PATH`) were removed again by this design; §5.1 (the clear error for a missing key name) stays. | 4 |
| This design | The status line, and what was built in another way. | last |

At the end, a search for `SSH_KEY_PATH` finds the name only in the two analysis notes, in this design and in older entries of `CHANGELOG.md`.

## 12. Not verified, and open

- Nothing was compiled or run for this design.
- The dartssh2 source was not read. Open: how `SSHIdentity.custom` names the RSA algorithm and wraps the signature of the agent (`SSHRawSignature`); whether the four clients compile unchanged.
- `ssh -i <public key file>` with `IdentitiesOnly=yes` picks the matching key of the agent according to `ssh_config(5)`; not tried here.
- What `mcp_dart` returns for an error that a tool does not catch.
- Whether a rescue or installer system that `provision` meets needs an algorithm that dartssh2 4 no longer offers. `provision` reaches such a system with `ssh`, not with dartssh2, so probably not.

## 13. Decisions of the operator

Made on 2026-11-18 for the companion design (its §11). What each one means for nix-infra:

| Decision | For nix-infra |
|---|---|
| `SSH_KEY_PATH` is removed, with no transition. | §8: a set value gives no error. |
| A lock of the sysops vault removes the keys from every agent; an unlock gives them back. | An agent that does not hold the key is a normal case, not a fault: the text of §7. nix-infra asks the agent at each login and keeps nothing from the agent between two logins. The key map is read again each time (§4.1). A connection that is already open is not ended. |
| sysops uses the `ssh-agent` of OpenSSH, one per terminal, probe run or agent session. | The tests with a real `ssh-agent` (§10) cover the agent that sysops uses. |
| "None" in sysops means no key of the vault. | sysops then sets no key map, so nix-infra uses the key files (§3). |
| sysops sets no deny rules for the file tools of an agent session. | The rule of §7 (no path in a text) stays. The limit is in §9. |
