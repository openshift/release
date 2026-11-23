# AGENTS.md — Guide for AI Coding Agents (agent-sandbox step-registry)

Guidance for AI agents authoring the **agent-sandbox** reusable CI
components — refs (steps) and workflows. It complements the human-focused
`README.md`.

**Scope split** — two AGENTS.md cover agent-sandbox CI; keep changes in the
right one:
- **This file** covers the *step-registry side*: refs, `-commands.sh` scripts,
  workflows, and the runtime-container constraints that shape step scripts.
- Pipeline images, `build_root`, `base_images`, and how a job is wired to a
  workflow live in the config guide:
  [`../../config/openshift/kubernetes-sigs-agent-sandbox/AGENTS.md`](../../config/openshift/kubernetes-sigs-agent-sandbox/AGENTS.md).

Read the repository-root `CLAUDE.md` first for general repo structure.

## Layout & Naming

- This file: `ci-operator/step-registry/agent-sandbox/AGENTS.md`
- A **ref** (step) is a dir with three files sharing the step name prefix:
  `<name>-ref.yaml`, `<name>-commands.sh`, `<name>-ref.metadata.json`.
- **Workflows** (`<name>-workflow.yaml`) define full `pre`/`test`/`post`
  scenarios.
- Registry validation fails if a step dir contains any file whose name does not
  match the expected prefixes — including editor swap files (`*.swp`).
- Every directory has an `OWNERS` file (real copy, not symlink).

```
agent-sandbox/
├── AGENTS.md                    # this file
├── README.md                    # human-focused docs
├── OWNERS                       # top-level OWNERS
├── install-operator/            # ref: installs agent-sandbox via OLM
│   ├── ...-ref.yaml
│   ├── ...-commands.sh
│   └── ...-ref.metadata.json
├── e2e/
│   ├── test/                    # ref: runs agent-sandbox e2e tests
│   │   ├── ...-ref.yaml
│   │   ├── ...-commands.sh
│   │   └── ...-ref.metadata.json
│   └── azure/                   # workflow: Azure standalone (no OSC)
│       └── ...-workflow.yaml
├── kata-e2e/
│   ├── OWNERS
│   ├── azure/                   # workflow: Azure + kata
│   │   └── ...-workflow.yaml
│   └── gcp/                     # workflow: GCP + kata
│       └── ...-workflow.yaml
└── peerpods-e2e/
    ├── OWNERS
    ├── azure/                   # workflow: Azure + peer-pods
    │   └── ...-workflow.yaml
    └── aws/                     # workflow: AWS + peer-pods
        └── ...-workflow.yaml
```

## Refs

### `agent-sandbox-install-operator`
Installs the agent-sandbox operator via OLM. Applies Konflux FBC mirror image
content source policies, creates CatalogSource + Namespace + OperatorGroup +
Subscription, waits for CSV `Succeeded` and controller deployment `Available`.

- `from: cli` — needs `oc`
- Key env vars: `AGENT_SANDBOX_INSTALL` (gate, default `"true"`),
  `AGENT_SANDBOX_CATALOG_IMAGE`, `AGENT_SANDBOX_PACKAGE`,
  `AGENT_SANDBOX_CHANNEL`, `AGENT_SANDBOX_NAMESPACE`

### `agent-sandbox-e2e-test`
Runs Go e2e tests from `./test/e2e/extensions/...` via `gotestsum`.

- `from: src` (needs git + source), `cli: latest` (provides `oc`)
- Key env vars: `SANDBOX_RUNTIME_CLASS` (default `"kata"`; set to `"kata-remote"`
  for peer-pods), `SANDBOX_TEST_TIMEOUT`, `SANDBOX_TEST_PATTERN`

## Workflows

All five workflows share the same test step (`agent-sandbox-e2e-test`).
The difference is cloud provisioning (pre/post), whether OSC is installed,
and whether peer-pods networking is configured.

### `agent-sandbox-e2e-azure`
Azure standalone (no OSC). Pre: `ipi-azure-pre` → `install-operator`.
Post: `ipi-azure-post`. Uses `SANDBOX_RUNTIME_CLASS: default` (cluster's
default runtime), testing operator lifecycle without kata/peer-pods.

### `agent-sandbox-kata-e2e-azure`
Azure + kata. Pre: `sandboxed-containers-operator-ipi-azure-pre` →
`env-cm` → `install-osc-operator` → `install-operator`. Post:
`gather-must-gather` → `ipi-azure-post`.

### `agent-sandbox-kata-e2e-gcp`
GCP + kata. Pre: `ipi-gcp-pre` → `env-cm` → `install-osc-operator` →
`install-operator`. Post: `gather-must-gather` → `ipi-gcp-post`.
Uses `COMPUTE_NODE_TYPE: n2-standard-4` (Intel, nested virtualization).

### `agent-sandbox-peerpods-e2e-azure`
Azure + peer-pods. Pre: `sandboxed-containers-operator-ipi-azure-pre` →
`peerpods-param-cm` → `env-cm` → `install-osc-operator` →
`install-operator`. Post: `gather-must-gather` → `ipi-azure-post`.
The `peerpods-param-cm` step must precede `env-cm` and `install-osc-operator`.

### `agent-sandbox-peerpods-e2e-aws`
AWS + peer-pods. Pre: `ipi-conf-aws` → `aws-provision-iam` →
`aws-region-override` → `ipi-install` → `peerpods-param-cm` → `env-cm` →
`install-osc-operator` → `install-operator`. Post: `gather-must-gather` →
`ipi-aws-post`. The `peerpods-param-cm` runs after cluster install because it
queries the cluster for VPC/subnet/security-group info.

## Reused SCO Components

These refs and chains are owned by the sandboxed-containers-operator team and
referenced from agent-sandbox workflows. Do not modify them here; changes
belong in the SCO step-registry tree.

| Component | Purpose |
|---|---|
| `sandboxed-containers-operator-env-cm` | Creates `osc-config` ConfigMap |
| `sandboxed-containers-operator-install-osc-operator` | Installs OSC for kata RuntimeClass |
| `sandboxed-containers-operator-peerpods-param-cm` | Cloud-specific peer-pods networking |
| `sandboxed-containers-operator-gather-must-gather` | Collects must-gather artifacts |
| `sandboxed-containers-operator-ipi-azure-pre` | Azure cluster provisioning chain |
| `sandboxed-containers-operator-aws-region-override` | AWS region override for install-config |

## Runtime Container Constraints

Step containers run under the OpenShift restricted SCC as an arbitrary
non-root UID. `-commands.sh` cannot install packages.

- Keep `set -euo pipefail` without `-x`. `-x` traces every command with its
  arguments and leaks secrets.
- Never `echo` credentials, tokens, or kubeconfig contents.
- Pass data between steps via `${SHARED_DIR}`, not by echoing to logs.
- Disable tracing around unavoidable sensitive operations and restore afterward.

## Verify Changes

```bash
make registry-metadata    # regenerate step metadata after adding/renaming steps
make jobs                 # runs checkconfig, which loads & validates the registry
```

## Keeping This File Current

Update this file alongside any code change that affects what it describes:
directory renames, new steps or workflows, changes to pre/test/post phase
structure, new runtime constraints, or security conventions.
