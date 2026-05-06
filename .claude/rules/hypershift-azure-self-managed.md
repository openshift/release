---
paths:
  - "ci-operator/step-registry/hypershift/azure/e2e/self-managed/**"
  - "ci-operator/step-registry/hypershift/azure/run-e2e-self-managed/**"
  - "ci-operator/step-registry/hypershift/azure/setup-private-link/**"
---

# HyperShift Azure Self-Managed

Shared Azure context (resources, credentials, BYO networking, encryption) is in `hypershift-azure-common.md`.

## Architecture

Uses **OpenShift management clusters** — the same nested management cluster pattern as AWS. A nested OpenShift HostedCluster is created on a pre-existing root cluster, then the HyperShift operator is installed on it.

This is different from managed Azure (ARO-HCP), which uses AKS as the management cluster.

Key distinction: self-managed sets `AZURE_SELF_MANAGED=true`, which skips the `--managed-service=ARO-HCP` flag during hypershift install. When Private Link credentials are available, it also adds `--private-platform=Azure`, `--azure-private-creds`, and `--azure-pls-resource-group` flags.

## Workflow

`hypershift-azure-e2e-self-managed`:
1. RBAC setup via `ipi-install-rbac`
2. Set up nested OpenShift management cluster via `hypershift-setup-nested-management-cluster` (with `CLOUD_PROVIDER=Azure`)
3. Configure Azure Private Link via `hypershift-azure-setup-private-link`
4. Install HyperShift operator via `hypershift-install` (with `AZURE_SELF_MANAGED=true`)
5. Run e2e tests via `hypershift-azure-run-e2e-self-managed`
6. Destroy management cluster via `hypershift-destroy-nested-management-cluster`

## Cluster Profile

`hypershift-azure`

## Management Cluster Details

- Root cluster kubeconfig: `/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig`
- Cluster name: derived from `PROW_JOB_ID` hash (same pattern as AWS)
- Instance type: `Standard_D16s_v3` (default)
- Etcd storage class: `managed-csi-premium-v2` (Premium SSD v2, created during setup)
- Base domain: `hcp-sm-azure.azure.devcluster.openshift.com`
- Location: `centralus`

## Private Link

Self-managed Azure uses Azure Private Link to provide secure connectivity between the management cluster and hosted cluster API servers.

Setup step: `hypershift-azure-setup-private-link`

Private Link artifacts in SHARED_DIR:
- `azure_pls_resource_group` — resource group for Private Link Services
- `azure_private_link_creds_file` — Private Link credentials
- `azure_private_nat_subnet_id` — NAT subnet for private endpoints

## Self-Managed-Specific Credentials

In addition to the shared credentials in `hypershift-azure-common.md`:

| Mount Path | Contents |
|---|---|
| `/etc/hypershift-ci-jobs-self-managed-azure/credentials.json` | Self-managed Azure service principal |
| `/etc/hypershift-ci-jobs-self-managed-azure-e2e/` | Self-managed e2e-specific creds |
| `/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig` | Root management cluster kubeconfig |
| `/etc/hypershift-additional-pull-secret/.dockerconfigjson` | Additional pull secret for e2e tests |

## Self-Managed-Specific Environment Variables

In addition to the shared env vars in `hypershift-azure-common.md`:

| Variable | Default | Purpose |
|---|---|---|
| `AZURE_SELF_MANAGED` | true | Self-managed mode (skips `--managed-service=ARO-HCP`) |
| `CLOUD_PROVIDER` | Azure | Cloud provider for management cluster setup |
| `HYPERSHIFT_ETCD_STORAGE_CLASS` | managed-csi-premium-v2 | Storage class for etcd |
| `HYPERSHIFT_NODE_COUNT` | 2 | Worker node count |
| `AZURE_PRIVATE_CREDS_FILE` | | Path to Private Link credentials |
| `AZURE_PLS_RESOURCE_GROUP` | | Resource group for Private Link Services |
| `AZURE_PRIVATE_NAT_SUBNET_ID` | (empty) | NAT subnet for private endpoints (alternative to SHARED_DIR file) |
| `CI_TESTS_RUN` | (empty) | Regex filter for e2e test selection |
| `HYPERSHIFT_EXTERNAL_DNS_DOMAIN` | aks-e2e.hypershift.azure.devcluster.openshift.com | External DNS domain (workflow default) |
| `HYPERSHIFT_AZURE_ZONES` | (empty) | Availability zones for hosted cluster |
| `E2E_RESOURCE_REQUEST_OVERRIDES` | (empty) | Resource request overrides for e2e tests |

## Self-Managed-Specific SHARED_DIR Artifacts

In addition to the shared artifacts in `hypershift-azure-common.md`:

| File | Purpose |
|---|---|
| `kubeconfig` | Copy of management cluster kubeconfig |
| `azure_pls_resource_group` | Private Link Services resource group |
| `azure_private_link_creds_file` | Private Link credentials |
| `azure_private_nat_subnet_id` | NAT subnet for private endpoints |

## Self-Managed Subdirectories

- `e2e/self-managed/` — self-managed e2e workflow definition
- `run-e2e-self-managed/` — e2e test execution (ref + commands script)
- `setup-private-link/` — Azure Private Link/Private Endpoint setup
