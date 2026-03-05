# Ephemeral Namespace Workflow

This workflow provisions and tears down an ephemeral namespace on the
consoledot ephemeral cluster using [bonfire](https://github.com/RedHatInsights/bonfire).

## Components

| Component | Type | Description |
|---|---|---|
| `ephemeral-namespace` | workflow | Top-level workflow with pre/post phases. Test phase is empty — consumers inject their own test steps. |
| `ephemeral-namespace-reserve` | ref (pre) | Logs into the ephemeral cluster, installs bonfire, reserves a namespace, and writes connection details to `SHARED_DIR`. |
| `ephemeral-namespace-release` | ref (post) | Reads the namespace from `SHARED_DIR` and releases it back to the pool. Runs as `best_effort` so it always executes. |

## Quick Start

Reference the workflow from a `ci-operator` config test definition:

```yaml
tests:
- as: my-ephemeral-test
  steps:
    workflow: ephemeral-namespace
    test:
    - ref: my-test-step
```

In your test step's commands script, read the namespace and kubeconfig:

```bash
#!/bin/bash
set -euo pipefail

# Switch to the ephemeral cluster
export KUBECONFIG="${SHARED_DIR}/ephemeral-kubeconfig"
NAMESPACE=$(cat "${SHARED_DIR}/ephemeral-namespace")

echo "Running tests in namespace: ${NAMESPACE}"
oc project "${NAMESPACE}"

# Your test logic here
bonfire deploy my-app --namespace "${NAMESPACE}" ...
```

## SHARED_DIR Outputs

The reserve step writes these files for downstream consumption:

| File | Content |
|---|---|
| `ephemeral-namespace` | The reserved namespace name (e.g., `ephemeral-abc123`) |
| `ephemeral-kubeconfig` | A kubeconfig file authenticated to the ephemeral cluster, with the context set to the reserved namespace |
| `ephemeral-cluster-server` | The API server URL of the ephemeral cluster |

## Environment Variables

All parameters have sensible defaults and can be overridden at the
workflow, chain, or individual test level:

| Variable | Default | Description |
|---|---|---|
| `BONFIRE_NAMESPACE_POOL` | `default` | Namespace pool to reserve from. Maps to `bonfire namespace reserve --pool`. |
| `BONFIRE_NAMESPACE_DURATION` | `1h` | Reservation duration (min 30m, max 14d). Format: `XhYmZs`. |
| `BONFIRE_NAMESPACE_TIMEOUT` | `600` | Seconds to wait for a namespace to become available. |
| `BONFIRE_NAMESPACE_REQUESTER` | Job name | Identity recorded on the reservation. Defaults to `$JOB_NAME`. |
| `BONFIRE_VERSION` | `>=4.18.0` | PyPI version specifier for `crc-bonfire`. |

Example override in a ci-operator config:

```yaml
tests:
- as: my-test
  steps:
    workflow: ephemeral-namespace
    test:
    - ref: my-test-step
    env:
      BONFIRE_NAMESPACE_POOL: minimal
      BONFIRE_NAMESPACE_DURATION: 2h
```

## Required Secret

The workflow requires the `ephemeral-bot-svc-account` secret in the
`test-credentials` namespace. This secret must contain:

| Key | Description |
|---|---|
| `oc-login-token` | OAuth/service-account token for the ephemeral cluster |
| `oc-login-server` | API server URL (e.g., `https://api.crc-eph.r9lp.p1.openshiftapps.com:6443`) |

This secret is mounted at `/usr/local/ci-secrets/ephemeral-cluster` in
both the reserve and release steps.

## How It Works

### Pre Phase (Reserve)

1. Reads cluster credentials from the mounted secret
2. Installs `crc-bonfire` into an isolated Python virtualenv
3. Creates a separate kubeconfig to avoid clobbering the CI-provided one
4. Logs into the ephemeral cluster using `oc login`
5. Calls `bonfire namespace reserve` with the configured pool, duration, and timeout
6. Writes the namespace name, kubeconfig, and server URL to `SHARED_DIR`

### Test Phase (User-Provided)

The test phase is empty in the workflow definition. Consumers inject
their own test steps which can use `SHARED_DIR/ephemeral-kubeconfig`
to interact with the reserved namespace.

### Post Phase (Release)

1. Reads the namespace name from `SHARED_DIR/ephemeral-namespace`
2. Logs into the ephemeral cluster (independent of the pre step)
3. Calls `bonfire namespace release` to return the namespace to the pool
4. Falls back to direct `NamespaceReservation` CR patching if bonfire fails
5. Runs as `best_effort` — executes even if the test phase failed

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                  ephemeral-namespace                  │
│                     (workflow)                        │
├──────────────────────────────────────────────────────┤
│                                                      │
│  ┌─── pre ────────────────────────────────────────┐  │
│  │  ephemeral-namespace-reserve                   │  │
│  │  • Login to ephemeral cluster                  │  │
│  │  • bonfire namespace reserve                   │  │
│  │  • Write kubeconfig + namespace to SHARED_DIR  │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ┌─── test ───────────────────────────────────────┐  │
│  │  (empty — consumer injects test steps here)    │  │
│  │  • Read KUBECONFIG from SHARED_DIR             │  │
│  │  • Run tests in the reserved namespace         │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ┌─── post ───────────────────────────────────────┐  │
│  │  ephemeral-namespace-release  [best_effort]    │  │
│  │  • bonfire namespace release                   │  │
│  │  • Fallback: patch NamespaceReservation CR     │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
└──────────────────────────────────────────────────────┘
```

## Troubleshooting

**Namespace reservation times out:**
The ephemeral pool may be full. Increase `BONFIRE_NAMESPACE_TIMEOUT` or
check pool utilization with `bonfire namespace list --available`.

**Release step fails:**
The step includes a fallback that patches the `NamespaceReservation` CR
directly. If both mechanisms fail, check the CI job logs and manually
release the namespace via `bonfire namespace release <ns> -f`.

**Authentication errors:**
Verify the `ephemeral-bot-svc-account` secret contains valid credentials.
The token may have expired or the service account may need rotation.
