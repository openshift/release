---
paths:
  - "ci-operator/step-registry/hypershift/azure/**"
---

# HyperShift Azure — Common Context

Azure HyperShift has two deployment models. See the model-specific rules for details:
- **Managed (ARO-HCP)**: AKS management cluster — see `hypershift-azure-managed.md`
- **Self-managed**: OpenShift management clusters — see `hypershift-azure-self-managed.md`

## Azure Resources Created (Both Models)

- Resource Groups (custom or auto-generated)
- VNets, Subnets, NSGs (or BYO via `HYPERSHIFT_CUSTOM_VNET/SUBNET/NSG`)
- VM instances for NodePools
- Managed Identities (control plane and data plane)
- Azure Key Vault for secrets and encryption
- Disk Encryption Sets (DES) for disk encryption
- Azure DNS zones for KAS DNS management
- Storage accounts for diagnostics

## Shared Credentials

| Mount Path | Contents |
|---|---|
| `/etc/hypershift-ci-jobs-azurecreds/credentials.json` | Azure service principal |
| `/etc/hypershift-ci-jobs-azurecreds/oidc-issuer-url.json` | OIDC issuer URL for WIF |
| `/etc/hypershift-ci-jobs-azurecreds/serviceaccount-signer.private` | SA token signing key |
| `/etc/ci-pull-credentials/.dockerconfigjson` | Docker pull secrets |

## Shared Environment Variables

| Variable | Purpose |
|---|---|
| `HYPERSHIFT_AZURE_LOCATION` | Azure region (centralus for self-managed, eastus for managed) |
| `HYPERSHIFT_EXTERNAL_DNS_DOMAIN` | External DNS domain |
| `HYPERSHIFT_DYNAMIC_DNS` | Custom KAS DNS name |
| `HYPERSHIFT_CUSTOM_RESOURCE_GROUP` | Use custom resource group from `${SHARED_DIR}/resourcegroup` |
| `HYPERSHIFT_CUSTOM_VNET` | BYO VNet from `${SHARED_DIR}/azure_vnet_id` |
| `HYPERSHIFT_CUSTOM_SUBNET` | BYO subnet from `${SHARED_DIR}/azure_subnet_id` |
| `HYPERSHIFT_CUSTOM_NSG` | BYO NSG from `${SHARED_DIR}/azure_nsg_id` |
| `HYPERSHIFT_DISK_ENCRYPTION` | Use DES from `${SHARED_DIR}/azure_des_id` |
| `HYPERSHIFT_ETCD_ENCRYPTION` | Use Key Vault key from `${SHARED_DIR}/azure_active_key_url` |
| `HYPERSHIFT_ENCRYPTION_AT_HOST` | VM host encryption (Enabled/Disabled) |
| `HYPERSHIFT_NP_AUTOREPAIR` | Machine autorepair with health checks |
| `HYPERSHIFT_AZURE_FIPS` | Enable FIPS mode |

## Shared SHARED_DIR Artifacts

| File | Purpose |
|---|---|
| `azure_des_id` | Disk Encryption Set resource ID |
| `azure_active_key_url` | Key Vault encryption key URL |
| `azure_vnet_id` | Virtual Network resource ID |
| `azure_subnet_id` | Subnet resource ID |
| `azure_nsg_id` | Network Security Group resource ID |
| `azure_storage_account_blob_endpoint` | Storage account URI (diagnostics) |
| `resourcegroup` | Custom resource group name |
| `nested_kubeconfig` | Guest cluster kubeconfig |
| `cluster-name` | Generated cluster name |
