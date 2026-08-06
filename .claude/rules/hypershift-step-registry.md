---
paths:
  - "ci-operator/step-registry/hypershift/**"
---

# HyperShift Step Registry

## Architecture Overview

HyperShift separates the hosted cluster control plane from the data plane:
- **Management cluster**: hosts control plane components as pods in a namespace
- **Guest/hosted cluster**: runs worker nodes with user workloads
- In CI, this is a 3-tier model: Root cluster → Nested management cluster → HostedCluster

## Management Cluster Model

- **Root cluster**: pre-existing shared OpenShift cluster, accessed via credential kubeconfig (`hypershift-ops-admin.kubeconfig`)
- **Nested management cluster**: ephemeral HostedCluster created on the root cluster per CI job. Cluster name derived from `PROW_JOB_ID` hash for uniqueness
- Setup: `hypershift-setup-nested-management-cluster` chain
- Destroy: `hypershift-destroy-nested-management-cluster` chain
- Outputs to SHARED_DIR: `management_cluster_kubeconfig`, `management_cluster_name`, `management_cluster_namespace`
- **Root management cluster (alternative)**: `hypershift-setup-root-management-cluster` chain copies the root kubeconfig to `${SHARED_DIR}/kubeconfig` (not `management_cluster_kubeconfig`) without creating a nested cluster. Used by `hypershift-aws-e2e-external` and `hypershift-aws-conformance` for a simpler 2-tier model (root cluster → HostedCluster)

Azure managed (ARO-HCP) is the exception — it uses AKS as management cluster instead of nested OpenShift.

## Workflow Composition (pre/test/post)

Most common workflow pattern (3-tier nested):
- **PRE**: `ipi-install-rbac` → management cluster setup → `hypershift-install` (operator deployment) → platform-specific create (e.g., `hypershift-aws-create`)
- **TEST**: `run-e2e` or `conformance` chain
- **POST**: destroy management cluster (dump is embedded in the destroy chain for 3-tier nested workflows; 2-tier workflows use separate `hypershift-dump` + platform-specific destroy)
- Some workflows set `allow_best_effort_post_steps: true` to ensure cleanup runs even on test failure (e.g., `hypershift-agent-conformance`, `hypershift-aws-reqserving-e2e`); most workflows rely on default post-step behavior

Alternative PRE patterns:
- **Root management cluster (no nested, 2-tier)**: `hypershift-setup-root-management-cluster` copies root kubeconfig directly, skips `hypershift-install` (operator already on root cluster) (e.g., `hypershift-aws-conformance`, `hypershift-aws-e2e-external`)
- **Hostedcluster workflow**: `openshift-cluster-bot-rbac` → `hypershift-hostedcluster-create`
- **Agent conformance**: `assisted-baremetal-operator` → `enable-qe-catalogsource` → `hypershift-install` → `hypershift-agent-create`

## HyperShift Install Step

Deploys the HyperShift operator to the management cluster. Key controls:
- `CLOUD_PROVIDER`: AWS, Azure, or GCP
- `AKS`: whether management cluster is AKS (managed Azure)
- `AZURE_SELF_MANAGED`: skip `--managed-service=ARO-HCP` for self-managed Azure
- `TECH_PREVIEW_NO_UPGRADE`, `ENABLE_HYPERSHIFT_CERT_ROTATION_SCALE`
- `INSTALL_FROM_LATEST`: use `HYPERSHIFT_RELEASE_LATEST` instead of step image

## Dump and Debug

- `hypershift-dump` chain: `bin/hypershift dump cluster` collects artifacts
- `hypershift-debug`: outputs debug tool links
- `hypershift-k8sgpt`: AI-powered K8s diagnostics
- Azure has additional `hypershift-dump-azure-diagnostics` step

## E2E V2 Framework

- Uses `test-e2e-v2` binary from `hypershift-tests` image
- Ginkgo-based with JUnit reporting
- Reads `${SHARED_DIR}/cluster-name`, fixed namespace `clusters`
- Cleaner interface than V1 for test isolation

## Step Registry File Conventions

- `*-ref.yaml` + `*-commands.sh` = steps (atomic tasks with metadata and executable script)
- `*-chain.yaml` = chains (ordered step sequences)
- `*-workflow.yaml` = workflows (complete pre/test/post scenarios)
- Security: disable `set -x` around credential handling (see root CLAUDE.md for pattern)

## Common SHARED_DIR Artifacts

| Artifact | Purpose |
|---|---|
| `management_cluster_kubeconfig` | Kubeconfig for the management cluster |
| `management_cluster_name` | Name of the management cluster |
| `management_cluster_namespace` | Namespace for management cluster resources |
| `nested_kubeconfig` | Kubeconfig for the guest/hosted cluster |
| `cluster-name` | Name of the created hosted cluster |
| `kubeconfig` | Active kubeconfig (management or guest) |
| `mgmt_icsp.yaml` | Image content source policy |

## Common Environment Variables

| Variable | Purpose |
|---|---|
| `KUBECONFIG` | Active cluster kubeconfig |
| `CI_TESTS_RUN` | Regex filter for test selection |
| `CLOUD_PROVIDER` | AWS, Azure, GCP, etc. |
| `HYPERSHIFT_NODE_COUNT` | Worker node count |
| `HYPERSHIFT_HC_RELEASE_IMAGE` | Guest cluster release image |
| `HYPERSHIFT_BASE_DOMAIN` | Cluster FQDN base domain |
| `HYPERSHIFT_EXTERNAL_DNS_DOMAIN` | External DNS domain |
| `HYPERSHIFT_CP_AVAILABILITY_POLICY` | SingleReplica or HighlyAvailable |
| `ENDPOINT_ACCESS` | Public, PublicAndPrivate, or Private |
| `TECH_PREVIEW_NO_UPGRADE` | Skip upgrades for tech preview |
| `RUN_UPGRADE_TEST` | Enable upgrade tests |

## Directory Overview

**Platforms**: aws/, azure/, gcp/, ibmcloud/, kubevirt/, openstack/, powervs/, agent/
**MCE**: mce/ (Multicluster Engine with agent, kubevirt, power, ibmz support)
**Operations**: install/, hostedcluster/, conformance/, e2e-v2/, e2e-backuprestore/, operatorhub/, optional-operators/, performanceprofile/
**Infrastructure**: setup-nested-management-cluster/, setup-root-management-cluster/, destroy-nested-management-cluster/
**Diagnostics**: dump/, debug/, analyze-e2e-failure/, k8sgpt/
**AI/Automation**: agentic-qe/, review-agent/, jira-agent/, dependabot-triage/

## Timeouts

- Management cluster setup: 45m
- HostedCluster create: 35m (AWS), 45m (Azure), 60m (GCP, hostedcluster)
- E2E tests (V2): 30m
- E2E tests (V1 run-e2e): 2h
- Conformance tests: 4h (14400s)
- Dump operations: 15m
- Destroy: 25m (Azure hosted), 45m (AWS hosted), 1h (hostedcluster generic)
