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

Azure managed (ARO-HCP) is the exception — it uses AKS as management cluster instead of nested OpenShift.

## Workflow Composition (pre/test/post)

Standard workflow pattern:
- **PRE**: `ipi-install-rbac` → management cluster setup → platform-specific setup → `hypershift-install` (operator deployment)
- **TEST**: `run-e2e` or `conformance` chain
- **POST**: `hypershift-dump` (diagnostics) → destroy hosted cluster → destroy management cluster
- `allow_best_effort_post_steps: true` ensures cleanup runs even on test failure

## HyperShift Install Step

Deploys the HyperShift operator to the management cluster. Key controls:
- `CLOUD_PROVIDER`: AWS or Azure
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

- `*-ref.yaml` + `*-commands.sh` = steps (atomic tasks)
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

**Platforms**: aws/, azure/, gcp/, ibmcloud/, kubevirt/, openstack/, powervs/
**MCE**: mce/ (Multicluster Engine with agent, kubevirt, power, ibmz support)
**Operations**: install/, hostedcluster/, conformance/, e2e-v2/, e2e-backuprestore/
**Infrastructure**: setup-nested-management-cluster/, setup-root-management-cluster/, destroy-nested-management-cluster/
**Diagnostics**: dump/, debug/, analyze-e2e-failure/, k8sgpt/
**AI/Automation**: agent/, agentic-qe/, review-agent/, jira-agent/, dependabot-triage/

## Timeouts

- Management cluster setup: 45m
- HostedCluster create: 60m
- E2E tests: 30m
- Dump operations: 15m
- Destroy: 45m (management), 1h (hosted)
