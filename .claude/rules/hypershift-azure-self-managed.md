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

## Workflows

HyperShift's root-backed self-managed Azure e2e jobs use two workflows. Both create the nested management cluster on the `sm-azure-root-ci` root cluster in UK South. The `*-azure-v2` refs mount the root's credentials from the `ops/clusters/sm-azure-root-ci` group in the `hypershift-team` collection.

### `hypershift-azure-e2e-self-managed` (release-4.22 only)

Definition: `ci-operator/step-registry/hypershift/azure/e2e/self-managed/hypershift-azure-e2e-self-managed-workflow.yaml`

1. RBAC setup via `ipi-install-rbac`
2. Set up nested OpenShift management cluster via `hypershift-setup-nested-management-cluster-azure-v2`
3. Configure Azure Private Link via `hypershift-azure-setup-private-link-v2`
4. Install HyperShift operator via `hypershift-install-azure-v2-aks-dns` (with `AZURE_SELF_MANAGED=true`). It runs the same script as `hypershift-install-azure-v2`, but gives external-dns the AKS e2e zone's credentials, which the release-4.22 custom KAS certificate test needs.
5. Resolve NodePool release images via `hypershift-resolve-nodepool-releases`
6. Run e2e tests via `hypershift-azure-run-e2e-self-managed`
7. Dump and destroy the management cluster via `hypershift-dump-management-cluster-azure-v2`, `hypershift-dump-extra`, and `hypershift-destroy-nested-management-cluster-azure-v2`

Defaults: `HYPERSHIFT_NODE_COUNT=2` and `HYPERSHIFT_EXTERNAL_DNS_DOMAIN=aks-e2e.hypershift.azure.devcluster.openshift.com`.

### `hypershift-azure-e2e-v2-self-managed` (main and release-4.23 and later)

Definition: `ci-operator/step-registry/hypershift/azure/e2e/v2-self-managed/hypershift-azure-e2e-v2-self-managed-workflow.yaml`

It uses the same setup, Private Link, dump, and destroy refs, but installs the operator with `hypershift-install-azure-v2`. It also creates, dumps, and destroys guest clusters with the `hypershift-azure-*-selfmanaged-guests` chains and runs e2e tests with the `hypershift-azure-run-e2e-v2-selfmanaged` chain.

Defaults: `HYPERSHIFT_NODE_COUNT=6` and `HYPERSHIFT_EXTERNAL_DNS_DOMAIN=sm-azure-root-ci.hcp-sm-azure.azure.devcluster.openshift.com`, the root cluster's own DNS zone.

### Cucushift QE jobs

The self-managed Cucushift QE chains (`cucushift-installer-rehearse-azure-hypershift-*` and `cucushift-installer-rehearse-azure-ipi-ovn-hypershift-*`) don't use the root cluster. They provision their own Azure IPI management cluster and leave `HYPERSHIFT_AZURE_LOCATION` empty, so `hypershift-azure-create` uses the leased region. The rest of this file describes the root-backed workflows.

## Cluster Profile

`hypershift-azure`

## Management Cluster Details

- Root cluster kubeconfig: `/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig`
- Cluster name: derived from `PROW_JOB_ID` hash (same pattern as AWS)
- Instance type: `Standard_D16s_v5` (default)
- Etcd storage class: `managed-csi-premium-v2` (Premium SSD v2, created during setup)
- Base domain: `hcp-sm-azure.azure.devcluster.openshift.com`
- Location: `uksouth`

## Private Link

Self-managed Azure uses Azure Private Link to provide secure connectivity between the management cluster and hosted cluster API servers.

Setup step: `hypershift-azure-setup-private-link-v2`

Private Link artifacts in SHARED_DIR:
- `azure_pls_resource_group` — resource group for Private Link Services
- `azure_private_link_creds_file` — Private Link credentials
- `azure_private_nat_subnet_id` — NAT subnet for private endpoints

## Self-Managed-Specific Credentials

The e2e runner `hypershift-azure-run-e2e-self-managed` mounts these, in addition to the shared credentials in `hypershift-azure-common.md`:

| Mount Path | Contents |
|---|---|
| `/etc/hypershift-ci-jobs-self-managed-azure/credentials.json` | Self-managed Azure service principal (`azure-credentials` field) |
| `/etc/hypershift-ci-jobs-self-managed-azure-e2e/workload-identities.json` | Hosted cluster workload identities (`e2e-workload-identities` field) |
| `/etc/hypershift-ci-jobs-self-managed-azure-signer/serviceaccount-signer.private` | Service account token signing key (`serviceaccount-signer-private` field) |
| `/etc/hypershift-ci-jobs-self-managed-azure-oidc/oidc-issuer-url` | OIDC issuer URL (`oidc-issuer-url` field) |
| `/etc/hypershift-ci-jobs-self-managed-azure-private/private-credentials.json` | Private Link credentials (`private-link-credentials` field) |
| `/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig` | Root cluster kubeconfig (`hypershift-ops-admin-kubeconfig` field) |
| `/etc/hypershift-additional-pull-secret/.dockerconfigjson` | Additional pull secret for e2e tests |

Other steps mount different fields. See each ref for its exact mounts:
- `hypershift-setup-nested-management-cluster-azure-v2` (`ci-operator/step-registry/hypershift/setup-nested-management-cluster/azure-v2/`) mounts the management cluster's workload identities (`mgmt-workload-identities` field) at `/etc/hypershift-ci-jobs-self-managed-azure-e2e-mc/`, not the guest `e2e-workload-identities`.
- `hypershift-install-azure-v2-aks-dns` (`ci-operator/step-registry/hypershift/install/azure-v2-aks-dns/`) mounts the AKS e2e zone's DNS credentials from `ops/hypershift-aks-e2e-dns-credentials` at `/etc/hypershift-aks-e2e-dns-credentials/`.

## Self-Managed-Specific Environment Variables

In addition to the shared env vars in `hypershift-azure-common.md`:

| Variable | Default | Purpose |
|---|---|---|
| `AZURE_SELF_MANAGED` | true | Self-managed mode (skips `--managed-service=ARO-HCP`) |
| `CLOUD_PROVIDER` | Azure | Cloud provider for management cluster setup |
| `HYPERSHIFT_ETCD_STORAGE_CLASS` | managed-csi-premium-v2 | Storage class for etcd |
| `HYPERSHIFT_NODE_COUNT` | 2 (release-4.22 workflow), 6 (v2 workflow) | Worker node count |
| `AZURE_PRIVATE_CREDS_FILE` | | Path to Private Link credentials |
| `AZURE_PLS_RESOURCE_GROUP` | | Resource group for Private Link Services |
| `AZURE_PRIVATE_NAT_SUBNET_ID` | (empty) | NAT subnet for private endpoints (alternative to SHARED_DIR file) |
| `CI_TESTS_RUN` | (empty) | Regex filter for e2e test selection |
| `HYPERSHIFT_EXTERNAL_DNS_DOMAIN` | See [Workflows](#workflows) | External DNS domain (workflow default; release-4.22 e2e expects the AKS e2e zone) |
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
