# Agent-Sandbox CI Step Registry

Reusable CI components for the
[agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) operator,
which extends Kubernetes with sandbox-based workload isolation using kata
containers and peer-pods (cloud API adaptor).

## Steps (Refs)

### `agent-sandbox-install-operator`

Installs the agent-sandbox operator via OLM on an existing OCP cluster.

1. Applies Konflux FBC mirror image content source policies
2. Waits for MachineConfigPool rollout (mirror config triggers node reboot)
3. Creates CatalogSource from the Konflux FBC image
4. Creates Namespace, OperatorGroup, and Subscription
5. Waits for ClusterServiceVersion `Succeeded` phase
6. Waits for the controller-manager deployment `Available`

| Env var | Default | Description |
|---|---|---|
| `AGENT_SANDBOX_INSTALL` | `"true"` | Set to `"false"` to skip installation |
| `AGENT_SANDBOX_CATALOG_IMAGE` | *(required)* | Konflux FBC catalog image reference |
| `AGENT_SANDBOX_PACKAGE` | `"agent-sandbox-operator"` | OLM package name |
| `AGENT_SANDBOX_CHANNEL` | `"alpha"` | Subscription channel |
| `AGENT_SANDBOX_NAMESPACE` | `"agent-sandbox-operator-system"` | Target namespace |

### `agent-sandbox-e2e-test`

Runs the agent-sandbox Go e2e test suite using `gotestsum`.

Tests are sourced from `./test/e2e/extensions/...` in the agent-sandbox
repository (built into the `src` image). The test binary uses `oc` (injected via
`cli: latest`) to interact with the cluster.

| Env var | Default | Description |
|---|---|---|
| `SANDBOX_RUNTIME_CLASS` | `"kata"` | RuntimeClass to test (`kata`, `kata-remote`, or `default`) |
| `SANDBOX_TEST_TIMEOUT` | `"30m"` | Go test timeout |
| `SANDBOX_TEST_PATTERN` | `"TestRuntimeClassLifecycle\|TestRuntimeClassStartupComparison"` | Go test `-run` pattern filter |

## Workflows

### `agent-sandbox-e2e-azure`

Standalone e2e tests on Azure without OSC. Tests the agent-sandbox operator's
SandboxTemplate, WarmPool, and SandboxClaim lifecycle using the cluster's
default runtime (runc).

| Phase | Steps |
|---|---|
| pre | `ipi-azure-pre` → `agent-sandbox-install-operator` |
| test | `agent-sandbox-e2e-test` (SANDBOX_RUNTIME_CLASS=default) |
| post | `ipi-azure-post` |

Cluster profile: `openshift-org-azure`

### `agent-sandbox-kata-e2e-azure`

Kata e2e tests on Azure.

| Phase | Steps |
|---|---|
| pre | `sandboxed-containers-operator-ipi-azure-pre` → `sandboxed-containers-operator-env-cm` → `sandboxed-containers-operator-install-osc-operator` → `agent-sandbox-install-operator` |
| test | `agent-sandbox-e2e-test` |
| post | `sandboxed-containers-operator-gather-must-gather` → `ipi-azure-post` |

Cluster profile: `openshift-org-azure`

### `agent-sandbox-kata-e2e-gcp`

Kata e2e tests on GCP.

| Phase | Steps |
|---|---|
| pre | `ipi-gcp-pre` → `sandboxed-containers-operator-env-cm` → `sandboxed-containers-operator-install-osc-operator` → `agent-sandbox-install-operator` |
| test | `agent-sandbox-e2e-test` |
| post | `sandboxed-containers-operator-gather-must-gather` → `ipi-gcp-post` |

Cluster profile: `openshift-org-gcp`. Uses `n2-standard-4` compute nodes
(Intel, supports nested virtualization required for kata).

### `agent-sandbox-peerpods-e2e-azure`

Peer-pods e2e tests on Azure. Uses `kata-remote` RuntimeClass with
cloud API adaptor instead of local kata VMs.

| Phase | Steps |
|---|---|
| pre | `sandboxed-containers-operator-ipi-azure-pre` → `sandboxed-containers-operator-peerpods-param-cm` → `sandboxed-containers-operator-env-cm` → `sandboxed-containers-operator-install-osc-operator` → `agent-sandbox-install-operator` |
| test | `agent-sandbox-e2e-test` (SANDBOX_RUNTIME_CLASS=kata-remote) |
| post | `sandboxed-containers-operator-gather-must-gather` → `ipi-azure-post` |

Cluster profile: `azure-qe`. The `peerpods-param-cm` step configures Azure
NAT gateway, SSH keys, managed identity, and networking.

### `agent-sandbox-peerpods-e2e-aws`

Peer-pods e2e tests on AWS.

| Phase | Steps |
|---|---|
| pre | `ipi-conf-aws` → `aws-provision-iam-user-minimal-permission` → `sandboxed-containers-operator-aws-region-override` → `ipi-install` → `sandboxed-containers-operator-peerpods-param-cm` → `sandboxed-containers-operator-env-cm` → `sandboxed-containers-operator-install-osc-operator` → `agent-sandbox-install-operator` |
| test | `agent-sandbox-e2e-test` (SANDBOX_RUNTIME_CLASS=kata-remote) |
| post | `sandboxed-containers-operator-gather-must-gather` → `ipi-aws-post` |

Cluster profile: `aws-sandboxed-containers-operator`. The `peerpods-param-cm`
step runs after cluster install because it queries the live cluster for
VPC, subnet, and security group information. Uses `AWS_REGION_OVERRIDE: us-east-2`.

## Adding a New Cloud Provider

1. Create a new workflow directory under `kata-e2e/<cloud>/` or
   `peerpods-e2e/<cloud>/`
2. Use the appropriate IPI pre/post chains for the cloud provider
3. Copy OWNERS from the parent directory
4. Add the workflow reference to a config file in
   `ci-operator/config/openshift/kubernetes-sigs-agent-sandbox/`
5. Run `make update` to generate metadata and Prow jobs

## Adding a New OCP Version

1. Create a new config variant file:
   `openshift-kubernetes-sigs-agent-sandbox-main__kata-<NNN>.yaml`
2. Adjust `releases.latest` for the target OCP version
3. For OCP 5.0+, use `release` mode with explicit `base_images: upi-installer`
4. Stagger the cron schedule to avoid overlapping with other versions
5. Run `make update`

## Clusterbot Usage

Launch a cluster with an agent-sandbox workflow for manual testing:

```
/launch agent-sandbox-e2e-azure openshift-org-azure,4.22
/launch agent-sandbox-kata-e2e-azure openshift-org-azure,4.22
/launch agent-sandbox-kata-e2e-gcp openshift-org-gcp,4.22
/launch agent-sandbox-peerpods-e2e-azure azure-qe,4.22
/launch agent-sandbox-peerpods-e2e-aws aws-sandboxed-containers-operator,4.22
```
