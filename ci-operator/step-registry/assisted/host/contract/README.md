# Host Contract Provider Abstraction

A provider-agnostic interface that enables Assisted workflows to run on different infrastructure providers while maintaining 1:1 execution parity with Prow.

## Architecture

The host contract provides a clean abstraction between Assisted workflows and infrastructure providers:

```
Assisted Workflows → Host Contract Interface → Provider Implementation
                                           ↗ OFCIR (Prow)
                                           ↘ Local/SSH (ci-tool)
```

## How It Works

The host contract steps operate in two modes:

### Prow Mode (Default)
- Delegates to `ofcir-*` steps
- Creates standard OFCIR files: `packet-conf.sh`, `cir`, `server-ip`
- Zero changes to existing behavior

### Local Mode (`HOST_CONTRACT_LOCAL=true`)
- Creates OFCIR-compatible files pointing to SSH host
- Enables local/remote execution via ci-tool
- Same interface, different target

## Interface Compatibility

Downstream steps (like `assisted-ofcir-setup`) consume the same files regardless of provider:

- `${SHARED_DIR}/server-ip` - Host IP address
- `${SHARED_DIR}/server-sshport` - SSH port (if non-standard)
- `${SHARED_DIR}/cir` - Host metadata (JSON format)
- `${SHARED_DIR}/packet-conf.sh` - SSH configuration script

## Implementation

### Host Contract Steps

- `assisted-host-contract-acquire` - Provisions or configures host access
- `assisted-host-contract-gather` - Collects logs and artifacts
- `assisted-host-contract-release` - Cleans up resources
- `assisted-host-contract-baremetalds-pre` - Prepares baremetald environments using the host contract acquire step
- `assisted-host-contract-baremetalds-post` - Gathers artifacts and performs release for assisted baremetal workflows
- `assisted-host-contract-agent-pre` / `assisted-host-contract-agent-post` - Host-contract aware wrappers around the agent pre/post chains

### Workflow Integration

All `assisted-ofcir-*` workflows use the host contract steps and post chain:

```yaml
pre:
  - ref: assisted-host-contract-acquire     # was: ofcir-acquire
  - ref: assisted-ofcir-setup
  - chain: assisted-common-pre
test:
  - ref: assisted-baremetal-test
post:
  - ref: assisted-common-gather
  - ref: assisted-host-contract-gather      # was: ofcir-gather
  - ref: assisted-host-contract-release     # was: ofcir-release
```

Operator workflows that rely on the baremetalds post chain use `chain: assisted-host-contract-baremetalds-post` to gather artifacts and run the release step. Agent workflows use the host-contract wrappers (`assisted-host-contract-agent-pre` / `assisted-host-contract-agent-post`) alongside the new `assisted-host-contract-agent-*` workflows so they share the same provider-neutral interface.

## Benefits

✅ **Zero Breaking Changes** - All existing jobs work unchanged
✅ **Perfect Prow Compatibility** - Same execution paths in CI
✅ **Local Development** - Run identical workflows locally
✅ **Provider Extensibility** - Easy to add new infrastructure providers
✅ **Interface Stability** - Downstream steps require no modifications

## Usage

### In Prow (Automatic)
Workflows automatically use OFCIR provider - no configuration needed.

### With ci-tool (Local/SSH)
The ci-tool automatically sets `HOST_CONTRACT_LOCAL=true` and provides SSH connection details:

```bash
ci run --job-name e2e-metal-assisted-4-20 \
       --ssh-host my-server.example.com \
       --ssh-user root \
       --ssh-key ~/.ssh/id_rsa
```

## Migration Status

✅ **Completed**: All assisted-ofcir workflows converted to use the host-contract interface
✅ **Backward Compatible**: Existing job configurations work without changes
✅ **Ready for Use**: Can be used immediately with ci-tool for local execution
