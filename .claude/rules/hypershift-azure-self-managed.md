---
paths:
  - "ci-operator/step-registry/hypershift/azure/create-selfmanaged-guests/**"
  - "ci-operator/step-registry/hypershift/azure/destroy-selfmanaged-guests/**"
  - "ci-operator/step-registry/hypershift/azure/dump-selfmanaged-guests/**"
  - "ci-operator/step-registry/hypershift/azure/e2e/self-managed/**"
  - "ci-operator/step-registry/hypershift/azure/e2e/v2-self-managed/**"
  - "ci-operator/step-registry/hypershift/azure/run-e2e-self-managed/**"
  - "ci-operator/step-registry/hypershift/azure/run-e2e-v2-selfmanaged/**"
  - "ci-operator/step-registry/hypershift/azure/setup-private-link/**"
  - "ci-operator/step-registry/hypershift/self-managed-azure/**"
---

# HyperShift Azure Self-Managed

Shared Azure context (resources, credentials, BYO networking, encryption) is in `hypershift-azure-common.md`.

## Architecture

Uses **OpenShift management clusters** — the same nested management cluster pattern as AWS. A nested OpenShift HostedCluster is created on a pre-existing root cluster, then the HyperShift operator is installed on it.

This is different from managed Azure (ARO-HCP), which uses AKS as the management cluster.

Key distinction: self-managed sets `AZURE_SELF_MANAGED=true`, which skips the `--managed-service=ARO-HCP` flag during hypershift install. When Private Link credentials are available, it also adds `--private-platform=Azure`, `--azure-private-creds`, and `--azure-pls-resource-group` flags.

## Workflow

- `hypershift-azure-e2e-self-managed` runs the legacy e2e ref against a nested OpenShift management cluster.
- `hypershift-azure-e2e-v2-self-managed` creates three guest clusters, runs the v2 e2e suite, and destroys the guests and nested management cluster.
- `hypershift-self-managed-azure-e2e-backuprestore` enables the self-managed credential and workload identity selectors, uses `hypershift-azure-create`, `hypershift-self-managed-azure-oadp-setup`, backup/restore and conformance tests, then `hypershift-self-managed-azure-oadp-destroy` and `hypershift-azure-destroy`. The OADP workflow and refs live under `hypershift/self-managed-azure/`.

Each workflow sets `CLOUD_PROVIDER=Azure` and `AZURE_SELF_MANAGED=true` and provisions a nested management cluster before guest cluster creation.

## Cluster Profile

`hypershift-azure`

## Management Cluster Details

- Root cluster kubeconfig: `/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig`
- Cluster name: derived from `PROW_JOB_ID` hash (same pattern as AWS)
- Instance type: `Standard_D16s_v5` (default)
- Nested management cluster etcd storage class: `managed-csi-premium-v2` (Premium SSD v2, created during setup)
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

Self-managed steps use these mounts; each step declares the ones it needs:

| Mount Path | Contents |
|---|---|
| `/etc/hypershift-ci-jobs-self-managed-azure/credentials.json` | Self-managed Azure service principal |
| `/etc/hypershift-ci-jobs-self-managed-azure-e2e/` | Self-managed e2e-specific creds |
| `/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig` | Root management cluster kubeconfig |
| `/etc/hypershift-additional-pull-secret/.dockerconfigjson` | Additional pull secret for e2e tests |

## Self-Managed-Specific Environment Variables

In addition to the shared env vars in `hypershift-azure-common.md`:

| Variable | Purpose |
|---|---|
| `AZURE_SELF_MANAGED` | Self-managed mode (skips `--managed-service=ARO-HCP`) |
| `CLOUD_PROVIDER` | Select Azure management cluster setup |
| `HYPERSHIFT_ETCD_STORAGE_CLASS` | Guest cluster etcd storage class |
| `HYPERSHIFT_NODE_COUNT` | Node count requested by the active setup/create steps; set per workflow |
| `AZURE_PRIVATE_CREDS_FILE` | Path to Private Link credentials |
| `AZURE_PLS_RESOURCE_GROUP` | Resource group for Private Link Services |
| `AZURE_PRIVATE_NAT_SUBNET_ID` | NAT subnet for private endpoints (alternative to SHARED_DIR file) |
| `CI_TESTS_RUN` | Regex filter for e2e test selection |
| `HYPERSHIFT_EXTERNAL_DNS_DOMAIN` | External DNS domain; set per workflow |
| `HYPERSHIFT_AZURE_ZONES` | Availability zones for hosted cluster |
| `E2E_RESOURCE_REQUEST_OVERRIDES` | Resource request overrides for e2e tests |

The `hypershift-azure-create` chain and `hypershift-azure-run-e2e-self-managed` ref default `HYPERSHIFT_ETCD_STORAGE_CLASS` to `""`, so the flag is omitted when unset. The legacy, v2, and OADP self-managed workflows each set it to `managed-csi-premium-v2`.

## Self-Managed-Specific SHARED_DIR Artifacts

In addition to the shared artifacts in `hypershift-azure-common.md`:

| File | Purpose |
|---|---|
| `kubeconfig` | Copy of management cluster kubeconfig |
| `azure_pls_resource_group` | Private Link Services resource group |
| `azure_private_link_creds_file` | Private Link credentials |
| `azure_private_nat_subnet_id` | NAT subnet for private endpoints |

## Self-Managed Subdirectories

- `azure/e2e/self-managed/` — legacy e2e workflow
- `azure/e2e/v2-self-managed/` — v2 e2e workflow
- `azure/run-e2e-self-managed/` — legacy e2e test execution
- `azure/create-selfmanaged-guests/`, `azure/run-e2e-v2-selfmanaged/`, `azure/dump-selfmanaged-guests/`, and `azure/destroy-selfmanaged-guests/` — v2 guest lifecycle and tests
- `azure/setup-private-link/` — Azure Private Link setup
- `self-managed-azure/e2e-backuprestore/` — OADP backup/restore workflow
- `self-managed-azure/oadp-setup/` and `self-managed-azure/oadp-destroy/` — OADP resource lifecycle
