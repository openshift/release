---
paths:
  - "ci-operator/step-registry/hypershift/azure/aks/**"
  - "ci-operator/step-registry/hypershift/azure/run-e2e/**"
---

# HyperShift Azure Managed (ARO-HCP)

Also known as ARO HCP (Azure Red Hat OpenShift Hosted Control Planes).

Shared Azure context (resources, credentials, BYO networking, encryption) is in `hypershift-azure-common.md`.

## Architecture

Uses **AKS (Azure Kubernetes Service)** as the management cluster. AKS is a managed Kubernetes service — not OpenShift. The HyperShift operator is installed on AKS, and hosted cluster control planes run as pods on AKS.

This is different from self-managed Azure, which uses OpenShift management clusters.

## Workflow

`hypershift-azure-aks-e2e`:
1. Provision AKS cluster via `cucushift-installer-rehearse-azure-aks-provision`
2. Attach Azure Key Vault via `hypershift-azure-aks-attach-kv`
3. Install HyperShift operator via `hypershift-install` (with `AKS=true`)
4. Get guest annotations via `cucushift-hypershift-extended-k8s-mgmt-get-guest-annotations`
5. Run e2e tests via `hypershift-azure-run-e2e`
6. Deprovision AKS cluster

## Cluster Profile

`hypershift-aks`

## AKS-Specific Features

- Azure Key Vault integration for K8s secrets (via `azure-keyvault-secrets-provider` addon)
- AKS cluster autoscaler: `AKS_CLUSTER_AUTOSCALER_MIN_NODES` / `AKS_CLUSTER_AUTOSCALER_MAX_NODES`
- Marketplace image support: `HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_*` (publisher, offer, SKU, version)
- Managed service flag: `--managed-service=ARO-HCP` passed to hypershift install

## Managed-Specific Credentials

In addition to the shared credentials in `hypershift-azure-common.md`:

| Mount Path | Contents |
|---|---|
| `/etc/hypershift-ci-jobs-azurecreds/managed-identities.json` | Managed identity mappings |
| `/etc/hypershift-ci-jobs-azurecreds/dataplane-identities.json` | Data plane identity mappings |
| `/etc/hypershift-ci-jobs-azurecreds/aks-kms-info.json` | AKS KMS configuration |
| `/etc/hypershift-additional-pull-secret/.dockerconfigjson` | Additional pull secret for e2e tests |
| `/etc/hypershift-kubeconfig/hypershift-ops-admin.kubeconfig` | Root management cluster kubeconfig (MGMT_PARENT_KUBECONFIG default) |

## Managed-Specific Environment Variables

In addition to the shared env vars in `hypershift-azure-common.md`:

| Variable | Default | Purpose |
|---|---|---|
| `AKS` | false (overridden to `true` at workflow level) | Indicates management cluster is AKS |
| `USE_HYPERSHIFT_AZURE_CREDS` | false (overridden to `true` at workflow level) | Use HyperShift OSD account |
| `AUTH_THROUGH_CERTS` | false | Azure Key Vault certificate auth |
| `HYPERSHIFT_MANAGED_SERVICE` | ARO-HCP | Managed service identifier passed to hypershift install |
| `TECH_PREVIEW_NO_UPGRADE` | false | Skip upgrades for tech preview |
| `HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER` | aro4 | Azure Marketplace image offer |
| `HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER` | azureopenshift | Marketplace publisher |
| `HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION` | 419.6.20250523 | Marketplace image version (pinned, updated periodically) |
| `HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU` | aro_419 | Marketplace image SKU (pinned, updated periodically) |

## Managed-Specific SHARED_DIR Artifacts

In addition to the shared artifacts in `hypershift-azure-common.md`:

| File | Purpose |
|---|---|
| `hypershift_hc_annotations` | HostedCluster annotations (one per line) |
| `resourcegroup_aks` | AKS resource group name (used by attach-kv) |

## AKS Subdirectories

- `aks/e2e/` — AKS e2e workflow
- `aks/attach-kv/` — Key Vault attachment to AKS cluster
- `aks/conformance/` — AKS conformance tests
- `aks/external-oidc/` — External OIDC provider for AKS
- `run-e2e/` — e2e test execution for managed/AKS
