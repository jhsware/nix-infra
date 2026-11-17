# MCP servers: SSH keys from a key map — analysis

**Date:** 2026-11-17
**Status:** Proposed. Not decided, not implemented.
**Code reviewed:** `188897b` (`main`).
**Full note:** `sysops_server/docs/analysis/2026-11-17-ssh-keys-for-mcp-servers.md` (why, the alternatives, the sysops side). This note is the nix-infra side and can be read alone.
**Earlier note:** `docs/analysis/2026-11-17-ssh-key-resolution-external-identities.md` (`SSH_KEY_PATH` for the CLI).

---

## 1. The need

A program that starts an MCP server (sysops, or a person) holds private key files outside the project folder and wants the MCP server to use them: one key for every machine, or a different key per machine. It gives the paths of the files, never the key text.

Today the three MCP servers (`nix-infra-machine-mcp`, `nix-infra-cluster-mcp`, `nix-infra-dev-mcp`) cannot do that:

- They need the key name `SSH_KEY` and exit 2 without it (`bin/nix_infra_machine_mcp.dart:49-54`).
- They do not read `SSH_KEY_PATH`. `ProviderFactory.autoDetect` has the parameter `sshKeyPath` (`lib/providers/provider_factory.dart:35-40`), but the MCP servers do not pass it (`bin/nix_infra_machine_mcp.dart:59-63`). Only the CLI does.
- There is no input for a key per machine, apart from `ssh_key` in `servers.yaml`.

What already fits:

- A machine has its own key path: `ClusterNode.sshKeyPath` and `getEffectiveSshKeyPath` (`lib/types.dart:27-38, 61-72`). It is set where a node is built (`lib/providers/self_hosting.dart:270-280`, `lib/providers/hcloud.dart:149-153`).
- The key file is read at each connection (`lib/helpers.dart:163-168`).
- Every MCP tool builds its nodes at each call (`provider.getServers()`), so an input that is read there is current at every call.
- The configuration is `.env` overlaid with the process environment (`lib/helpers.dart:296-322`), so a variable works from both.

## 2. The input contract (proposed)

Two variables, read by the three MCP servers from the configuration (`.env` and the process environment):

| Variable | Meaning |
|---|---|
| `SSH_KEY_PATH` | One private key file for every machine. The rules of the CLI (`lib/ssh_key_path.dart:31-56`). |
| `SSH_KEY_MAP_PATH` | The absolute path of a JSON file, the key map: the key file of each machine, and a default. |

The CLI does not read `SSH_KEY_MAP_PATH`.

With a key from one of the two, the key name `SSH_KEY` is not necessary to connect.

### 2.1 The key map

```json
{
  "version": 1,
  "default": { "path": "/abs/keys/fleet-default" },
  "nodes": {
    "web-1": { "path": "/abs/keys/web" },
    "db-1":  { "unavailable": "secrets_locked", "ring": "interactive" }
  }
}
```

- `version` is `1`. Another version: the MCP server does not start.
- `default` and `nodes` are optional.
- An entry is `{"path": <absolute path>}` or `{"unavailable": <reason>}`, with an optional `ring` for the text of the error. A relative path is refused.
- The name of a machine is `ClusterNode.name`, compared exactly.
- Unknown fields are ignored at every level.
- The file is read each time the list of machines is built. The writer may replace it while the server runs.
- No name patterns: the writer resolves the key of each machine.

### 2.2 The order of the key sources of one machine

The first source that names the machine decides:

1. `nodes[<name>]` of the key map;
2. `default` of the key map;
3. `SSH_KEY_PATH`;
4. `ssh_key` of the machine in `servers.yaml`;
5. `ssh/<SSH_KEY>` in the project folder.

An `unavailable` entry, a key file that does not exist and a key map that cannot be read or is not valid are errors for that machine. They do not fall through to the next source: a machine is never tried with another key than the one that was chosen for it.

## 3. Texts must not show a path

The agent that calls the tools must not learn where a key file is. No tool result and no line on stderr holds the path of a key file or of the key map. A text names the machine and the variable.

Texts that show a path today or would with the new input:

| Where | Text | When |
|---|---|---|
| `lib/ssh.dart:84-86` (`Reason: <text of the exception>`) | the `PathNotFoundException` of `File.readAsString`, with the path | a key file that does not exist |
| `bin/mcp_server/file_upload.dart:126` (`ERROR - <text>`) | the same | the same |
| `lib/ssh_key_path.dart:50-54` | `SSH_KEY_PATH names a file that does not exist: <path>` | as soon as the MCP servers call `resolveSshKeyPath` |
| `lib/ssh_key_path.dart:90-91` | `Cannot derive the public key from <path>` | a tool that needs the public key |
| `lib/ssh.dart:30-33` | names no path, but says "in sysops: open a terminal with the key of this machine" | the wording is wrong for an MCP server |

Proposed texts for a tool result: "The SSH key of machine `<name>` is not available (`<reason>`)." and "The SSH key file of machine `<name>` does not exist. If sysops gave the key: the vault may be locked." The CLI keeps its texts: there the path helps the person at the terminal.

The stderr rule is there because the documentation of Claude Code does not say where the stderr of a stdio MCP server goes.

## 4. One more finding: `file-upload`

`file-upload` uploads any local path that the process can read, a folder with its content included (`bin/mcp_server/file_upload.dart:52-65, 82-113`). `configuration-files` is limited to folders of the project (`bin/nix_infra_machine_mcp.dart:144-158`); `file-upload` is not. An agent that has `file-upload` and `remote-command` can copy a key file to a machine and read it there. Proposed as its own task: `file-upload` takes local paths inside the project folder only.

## 5. Work

Two tasks exist in the planner and wait for the decision of the operator: "MCP servers: read SSH_KEY_PATH (one private key file for every machine)" and "MCP servers: SSH_KEY_MAP_PATH — the key file of each machine from a JSON file". The second is the one sysops needs.

Not verified: nothing was run for this note; what `mcp_dart` sends for an exception that a tool does not catch was not read (the text of the exception is assumed).
