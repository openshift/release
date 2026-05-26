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

## Shared Credentials (Both Models)

| Mount Path | Contents |
|---|---|
| `/etc/ci-pull-credentials/.dockerconfigjson` | Docker pull secrets |

### Create Chain Credentials

These credentials are used by the `hypershift-azure-create` chain. The primary self-managed e2e workflow uses different credential paths (see `hypershift-azure-self-managed.md`), but some cucushift-based self-managed workflows also use this chain.

| Mount Path | Contents |
|---|---|
| `/etc/hypershift-ci-jobs-azurecreds/credentials.json` | Azure service principal |
| `/etc/hypershift-ci-jobs-azurecreds/oidc-issuer-url.json` | OIDC issuer URL for WIF |
| `/etc/hypershift-ci-jobs-azurecreds/serviceaccount-signer.private` | SA token signing key |
| `/etc/hypershift-aro-azurecreds/` | ARO Azure creds (fallback when `USE_HYPERSHIFT_AZURE_CREDS` is false) |
| `/etc/hypershift-selfmanaged-azurecreds/workload-identities.json` | Self-managed workload identities (when `HYPERSHIFT_AZURE_SELF_MANAGED=true`) |

## Shared Environment Variables (Both Models)

| Variable | Purpose |
|---|---|
| `HYPERSHIFT_AZURE_LOCATION` | Azure region (default: eastus in create/destroy chains; overridden to centralus in self-managed workflow and ref) |
| `HYPERSHIFT_EXTERNAL_DNS_DOMAIN` | External DNS domain |
| `CI_TESTS_RUN` | Test regex filter for selecting which e2e tests to run |

### Create Chain Environment Variables

These env vars are defined in the `hypershift-azure-create` chain.

| Variable | Purpose |
|---|---|
| `USE_HYPERSHIFT_AZURE_CREDS` | Select HyperShift OSD credential set (true/false) |
| `HYPERSHIFT_AZURE_CP_MI` | Enable managed identity auth (true/false) |
| `HYPERSHIFT_AZURE_SELF_MANAGED` | Use self-managed workload identities file (true/false) |
| `HYPERSHIFT_DYNAMIC_DNS` | Custom KAS DNS name |
| `HYPERSHIFT_CUSTOM_RESOURCE_GROUP` | Use custom resource group from `${SHARED_DIR}/resourcegroup` |
| `HYPERSHIFT_CUSTOM_VNET` | BYO VNet from `${SHARED_DIR}/azure_vnet_id` |
| `HYPERSHIFT_CUSTOM_SUBNET` | BYO subnet from `${SHARED_DIR}/azure_subnet_id` |
| `HYPERSHIFT_CUSTOM_NSG` | BYO NSG from `${SHARED_DIR}/azure_nsg_id` |
| `HYPERSHIFT_DISK_ENCRYPTION` | Use DES from `${SHARED_DIR}/azure_des_id` |
| `HYPERSHIFT_ETCD_ENCRYPTION` | Use Key Vault key from `${SHARED_DIR}/azure_active_key_url` |
| `HYPERSHIFT_ENCRYPTION_AT_HOST` | VM host encryption (true/false) |
| `HYPERSHIFT_NP_AUTOREPAIR` | Machine autorepair with health checks |
| `HYPERSHIFT_AZURE_FIPS` | Enable FIPS mode |
| `HYPERSHIFT_NODE_COUNT` | NodePool replica count (default: 3 in create chain) |
| `DNS_ZONE_RG_NAME` | DNS zone resource group (default: os4-common; also used by destroy chain) |

## Shared SHARED_DIR Artifacts (Both Models)

| File | Purpose |
|---|---|
| `management_cluster_kubeconfig` | Management cluster kubeconfig |
| `management_cluster_name` | Management cluster name |
| `management_cluster_namespace` | Management cluster namespace |

### Create Chain SHARED_DIR Artifacts

These artifacts are consumed by the `hypershift-azure-create` chain from upstream provisioning steps, except `cluster-name` and `nested_kubeconfig` which are produced by the create chain. The destroy chain only reads `resourcegroup`.

| File | Direction | Purpose |
|---|---|---|
| `azure_des_id` | consumed | Disk Encryption Set resource ID |
| `azure_active_key_url` | consumed | Key Vault encryption key URL |
| `azure_vnet_id` | consumed | Virtual Network resource ID |
| `azure_subnet_id` | consumed | Subnet resource ID |
| `azure_nsg_id` | consumed | Network Security Group resource ID |
| `azure_storage_account_blob_endpoint` | consumed | Storage account URI (diagnostics) |
| `resourcegroup` | consumed | Custom resource group name (also read by destroy chain) |
| `hypershift_hc_annotations` | consumed | HostedCluster annotations (one per line, used for AKS) |
| `cluster-name` | produced | Generated cluster name |
| `nested_kubeconfig` | produced | Guest/hosted cluster kubeconfig |

### Destroy Chain

The `hypershift-azure-destroy` chain mounts `hypershift-ci-jobs-azurecreds` and uses the following env vars: `USE_HYPERSHIFT_AZURE_CREDS`, `HYPERSHIFT_AZURE_LOCATION`, `HYPERSHIFT_CUSTOM_RESOURCE_GROUP`, and `DNS_ZONE_RG_NAME`.
