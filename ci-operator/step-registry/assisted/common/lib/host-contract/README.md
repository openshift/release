# Assisted Host Provider Contract

The Assisted CI workflows now share a single **host provider contract** that
standardises how a reusable CI machine is described. This contract removes the
implicit coupling to provider specific assets such as `ofcir`'s `packet-conf.sh`
and allows the same workflows to run 1:1 on any environment that can satisfy the
contract (including the local CI tool).

The contract lives in the step registry so that:

- Provider specific acquisition steps (OFCIR today, other clouds tomorrow)
  populate a file with well-defined keys.
- Generic Assisted workflows read that file to obtain host connection metadata
  without knowing which provider supplied it.
- Local tooling can create the same file and reuse the upstream scripts without
  modification, guaranteeing parity.

This document explains the format, how providers should emit it, and how
consumers interact with it.

## Contract file

- **Location**: `${SHARED_DIR}/assisted-common-lib-host-contract-commands.sh` by default. Writers or
  consumers can override the path by setting `HOST_CONTRACT_PATH` before sourcing
  the helper library.
- **Format**: POSIX shell fragment containing one `export KEY=value` per line
  (it can be safely sourced).
- **Helper library**: `assisted-common-lib-host-contract-commands.sh` (next to this README) offers utilities
  to generate and consume the contract consistently.

### Required keys

| Key | Description |
| --- | ----------- |
| `HOST_PROVIDER` | Identifier for the provider implementation (e.g. `ofcir`, `nutanix`). |
| `HOST_PRIMARY_IP` | Reachable IP or hostname of the primary host that will run Assisted tests. |
| `HOST_PRIMARY_SSH_USER` | Username to connect to the host. |
| `HOST_PRIMARY_SSH_KEY_PATH` | Path to the SSH private key on the step host. |

### Optional keys

| Key | Default | Purpose |
| --- | ------- | ------- |
| `HOST_PRIMARY_NAME` | `primary` | Logical inventory name for the host. |
| `HOST_PRIMARY_SSH_PORT` | `22` | SSH port. |
| `HOST_PRIMARY_SSH_ADDITIONAL_OPTIONS` | `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR -o ConnectTimeout=5` | Additional `ssh` / `scp` CLI options. |
| `HOST_PRIMARY_SSH_KNOWN_HOSTS` | *(unset)* | Path to a pre-populated `known_hosts` file. Enables strict host key checking when provided. |
| `HOST_PRIMARY_SSH_BASTION` | *(unset)* | `ProxyJump`/bastion string if a jump host is required. |
| `HOST_PRIMARY_METADATA_PATH` | *(unset)* | Optional path to provider metadata dumped for later gathering. |
| `HOST_PRIMARY_ENV_PATH` | *(unset)* | Optional path to provider specific environment values. |

Providers may add additional `export` statements for debugging, but consumers
must rely only on the keys above.

## Writing the contract (provider steps)

Provider acquisition steps should source the helper and use the writer API to
emit the contract. Example:

```bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../common/lib/host-contract/assisted-common-lib-host-contract-commands.sh"

host_contract::writer::begin  # defaults to ${SHARED_DIR}/assisted-common-lib-host-contract-commands.sh
host_contract::writer::set HOST_PROVIDER "ofcir"
host_contract::writer::set HOST_PRIMARY_IP "$acquired_ip"
host_contract::writer::set HOST_PRIMARY_SSH_USER "root"
host_contract::writer::set HOST_PRIMARY_SSH_PORT "$ssh_port"
host_contract::writer::set HOST_PRIMARY_SSH_KEY_PATH "${CLUSTER_PROFILE_DIR}/packet-ssh-key"
host_contract::writer::set HOST_PRIMARY_SSH_ADDITIONAL_OPTIONS "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR -o ConnectTimeout=5"
# Optional metadata files can be exported here as well.
host_contract::writer::commit
```

Key points:

- `host_contract::writer::begin` creates/overwrites the target file.
- `host_contract::writer::set` safely quotes values (spaces are preserved).
- `host_contract::writer::commit` finalises the file and restricts permissions.

Providers should stop writing `packet-conf.sh`, custom SSH option snippets, or
other ad-hoc files once the contract is populated. Any additional provider
metadata can be stored alongside the contract (and referenced through
`HOST_PRIMARY_METADATA_PATH`).

## Consuming the contract (generic steps)

Generic Assisted steps load the contract once and reuse the helper to create the
artifacts they previously generated manually:

```bash
# shellcheck disable=SC1091
source "$(dirname "$0")/../common/lib/host-contract/assisted-common-lib-host-contract-commands.sh"

host_contract::load
host_contract::write_inventory "${SHARED_DIR}/inventory"
host_contract::write_ansible_cfg "${SHARED_DIR}/ansible.cfg"
host_contract::write_ssh_config "${SHARED_DIR}/ssh_config"

# Run Ansible using the exported SSH options
ansible-playbook -i "${SHARED_DIR}/inventory" playbook.yaml
```

The loader API provides:

- Normalised environment variables (`HOST_SSH_*`, `HOST_SSH_OPTIONS` array) for
  direct `ssh`/`scp` use.
- Convenience helpers to render inventory, `ansible.cfg`, and SSH config files in
  a consistent manner.
- Wrapper functions `host_contract::ssh`, `host_contract::scp_to_host`, and
  `host_contract::scp_from_host` for common operations.

Consumers **must not** attempt to read provider specific artifacts (e.g.
`packet-conf.sh`, `server-ip`). The contract is the single source of truth.

## Rationale and expectations

- **1:1 parity**: the same scripts run in Prow and the local CI tool. By defining
  a strict contract we avoid the need for local-only forks or heuristics.
- **Fail fast**: `host_contract::load` validates required keys and exits with a
  clear error if the contract is incomplete.
- **Idempotent**: re-running writer helpers replaces the contract in-place;
  consumer helpers regenerate derived artifacts safely.
- **Extensible**: new providers can be added by simply populating the contract.
  Generic workflows remain untouched.

## Migration checklist

1. Provider steps populate the contract file (and stop writing provider specific
   shell snippets).
2. All Assisted workflows and chains source `assisted-common-lib-host-contract-commands.sh` and use its
   helpers instead of `packet-conf.sh` or custom SSH scaffolding.
3. Documentation and troubleshooting guides reference the contract when
   discussing host setup.
4. Local tooling writes the same contract before invoking the upstream scripts.

Once every consumer relies on the contract the historical OFCIR-only artifacts
can be removed entirely.

