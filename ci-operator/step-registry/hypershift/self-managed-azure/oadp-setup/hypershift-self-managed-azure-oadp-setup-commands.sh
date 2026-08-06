#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
OADP_PLUGIN_IMAGE="${OADP_HYPERSHIFT_PLUGIN_IMAGE:-quay.io/konveyor/hypershift-oadp-plugin:latest}"

# TODO: This picks the "public" cluster by default. The hypershift-azure-create-selfmanaged-guests
# creates a number of clusters which is baked into the create-guests binary from HyperShift.
# We need to find a way tell the binary to create only a single cluster.
CLUSTER_PREFIX="${CLUSTER_PREFIX:-public}"

echo "Discovering the public self-managed-Azure guest cluster..."
CLUSTER_NAME="$(oc get hostedcluster -n clusters -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "${CLUSTER_PREFIX}" | head -n1 || true)"
if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "!!! Unable to find a public HostedCluster in the 'clusters' namespace"
  oc get hostedcluster -n clusters
  exit 1
fi
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

RESOURCEGROUP="$(cat "${SHARED_DIR}/azure_pls_resource_group")"
CONTAINER_PREFIX="hypershift-oadp-"
CONTAINER_NAME="${CONTAINER_PREFIX}${CLUSTER_NAME:0:$((63 - ${#CONTAINER_PREFIX}))}"
# Storage account names must be 3-24 chars, lowercase letters and numbers only.
# "oadp" (4) + sanitized cluster stem (up to 12) + job-unique hash (8) = max 24.
CLUSTER_STEM="$(echo "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]' | tr -cd '[:lower:][:digit:]')"
JOB_SUFFIX="$(echo -n "${PROW_JOB_ID:-unknown}" | md5sum | cut -c1-8)"
STORAGE_ACCOUNT_NAME="oadp${CLUSTER_STEM:0:12}${JOB_SUFFIX}"

echo "Setting up OADP prerequisites for backup/restore tests"
echo "Cluster: ${CLUSTER_NAME}, Resource Group: ${RESOURCEGROUP}, Storage Account: ${STORAGE_ACCOUNT_NAME}, Container: ${CONTAINER_NAME}"

echo "Reading Azure credentials..."
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

echo "Logging into Azure..."
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

echo "Creating storage account ${STORAGE_ACCOUNT_NAME} in resource group ${RESOURCEGROUP}..."
az storage account create \
  --name "${STORAGE_ACCOUNT_NAME}" \
  --resource-group "${RESOURCEGROUP}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none

# Save resource names for cleanup
echo "${STORAGE_ACCOUNT_NAME}" > "${SHARED_DIR}/oadp-storage-account-name"
echo "${RESOURCEGROUP}" > "${SHARED_DIR}/oadp-storage-resourcegroup"

echo "Creating blob container ${CONTAINER_NAME}..."
az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --auth-mode login \
  --output none

echo "Getting resource ID of storage account ${STORAGE_ACCOUNT_NAME} for role scope..."
STORAGE_ACCOUNT_ID="$(az storage account show --name "${STORAGE_ACCOUNT_NAME}" --resource-group "${RESOURCEGROUP}" --query id -o tsv)"
if [[ -z "${STORAGE_ACCOUNT_ID}" ]]; then
  echo "!!! Unable to resolve resource ID for storage account ${STORAGE_ACCOUNT_NAME}"
  exit 1
fi

# Create the openshift-adp namespace if it doesn't exist
oc get namespace openshift-adp 2>/dev/null || oc create namespace openshift-adp

echo "Setting up dedicated Azure Workload Identity for OADP (Velero + etcd-backup)..."

# Subjects hardcoded by the two consumers:
#  - HyperShift Operator's HCPEtcdBackup controller (hypershift ns, autodetected via BSL-copied credential)
#  - Velero + NodeAgent DaemonSet, which share ServiceAccount "velero" in openshift-adp
ETCD_BACKUP_SA_SUBJECT="system:serviceaccount:hypershift:etcd-backup-job"
VELERO_SA_SUBJECT="system:serviceaccount:openshift-adp:velero"

OADP_MI_NAME="oadp-workload-identity-${CLUSTER_NAME}"
OADP_MI_RESOURCEGROUP="os4-common"
OADP_MI_LOCATION="${HYPERSHIFT_AZURE_LOCATION:-centralus}"

echo "Creating managed identity ${OADP_MI_NAME} in resource group ${OADP_MI_RESOURCEGROUP}..."
az identity create \
  --name "${OADP_MI_NAME}" \
  --resource-group "${OADP_MI_RESOURCEGROUP}" \
  --location "${OADP_MI_LOCATION}" \
  --output none

# Persist identity coordinates immediately so the destroy step can find and
# remove it even if a later step in this block fails.
echo "${OADP_MI_NAME}" > "${SHARED_DIR}/oadp-workload-identity-name"
echo "${OADP_MI_RESOURCEGROUP}" > "${SHARED_DIR}/oadp-workload-identity-resourcegroup"

echo "Resolving client ID and principal ID of ${OADP_MI_NAME}..."
OADP_MI_CLIENT_ID=""
OADP_MI_PRINCIPAL_ID=""
for attempt in $(seq 1 5); do
  OADP_MI_CLIENT_ID="$(az identity show --name "${OADP_MI_NAME}" --resource-group "${OADP_MI_RESOURCEGROUP}" --query clientId -o tsv || true)"
  OADP_MI_PRINCIPAL_ID="$(az identity show --name "${OADP_MI_NAME}" --resource-group "${OADP_MI_RESOURCEGROUP}" --query principalId -o tsv || true)"
  if [[ -n "${OADP_MI_CLIENT_ID}" && -n "${OADP_MI_PRINCIPAL_ID}" ]]; then
    break
  fi
  echo "Attempt ${attempt}/5: identity not fully propagated yet, retrying in 10s..."
  sleep 10
done
if [[ -z "${OADP_MI_CLIENT_ID}" || -z "${OADP_MI_PRINCIPAL_ID}" ]]; then
  echo "!!! Failed to resolve clientId/principalId for managed identity ${OADP_MI_NAME}"
  exit 1
fi

echo "Resolving management cluster OIDC issuer..."
MGMT_OIDC_ISSUER="$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')"
if [[ -z "${MGMT_OIDC_ISSUER}" ]]; then
  echo "!!! Unable to resolve serviceAccountIssuer from the management cluster's Authentication config"
  exit 1
fi
echo "Management cluster OIDC issuer: ${MGMT_OIDC_ISSUER}"

# Creates one federated credential on ${OADP_MI_NAME}, retrying on transient
# failures. Args: <fedcred-name> <k8s-service-account-subject>
create_federated_credential() {
  local fedcred_name="$1"
  local subject="$2"
  local attempt
  for attempt in $(seq 1 5); do
    if az identity federated-credential create \
      --name "${fedcred_name}" \
      --identity-name "${OADP_MI_NAME}" \
      --resource-group "${OADP_MI_RESOURCEGROUP}" \
      --issuer "${MGMT_OIDC_ISSUER}" \
      --subject "${subject}" \
      --audiences "api://AzureADTokenExchange" \
      --output none; then
      return 0
    fi
    echo "Attempt ${attempt}/5: Failed to create federated credential ${fedcred_name}, retrying in 10s..."
    sleep 10
  done
  return 1
}

echo "Creating federated identity credential for etcd-backup..."
if ! create_federated_credential "etcd-backup-fedcred" "${ETCD_BACKUP_SA_SUBJECT}"; then
  echo "!!! Failed to create federated identity credential etcd-backup-fedcred after 5 attempts"
  exit 1
fi

echo "Creating federated identity credential for velero..."
if ! create_federated_credential "velero-fedcred" "${VELERO_SA_SUBJECT}"; then
  echo "!!! Failed to create federated identity credential velero-fedcred after 5 attempts"
  exit 1
fi

echo "Granting Storage Blob Data Contributor on ${STORAGE_ACCOUNT_NAME} to ${OADP_MI_NAME}..."
ROLE_ASSIGNED=false
for attempt in $(seq 1 5); do
  if az role assignment create \
    --assignee-object-id "${OADP_MI_PRINCIPAL_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" \
    --scope "${STORAGE_ACCOUNT_ID}" \
    --output none; then
    ROLE_ASSIGNED=true
    break
  fi
  echo "Attempt ${attempt}/5: Role assignment failed (likely AAD propagation delay), retrying in 15s..."
  sleep 15
done
if [[ "${ROLE_ASSIGNED}" != "true" ]]; then
  echo "!!! Failed to grant Storage Blob Data Contributor to ${OADP_MI_NAME} after 5 attempts"
  exit 1
fi

echo "Creating Azure credentials secret (Workload Identity mode, no client secret)..."
AZURE_CREDS_FILE="$(mktemp)"
cat <<EOF > "${AZURE_CREDS_FILE}"
AZURE_SUBSCRIPTION_ID=${AZURE_AUTH_SUBSCRIPTION_ID}
AZURE_TENANT_ID=${AZURE_AUTH_TENANT_ID}
AZURE_CLIENT_ID=${OADP_MI_CLIENT_ID}
AZURE_RESOURCE_GROUP=${RESOURCEGROUP}
AZURE_CLOUD_NAME=AzurePublicCloud
EOF

oc create secret generic cloud-credentials -n openshift-adp --from-file cloud="${AZURE_CREDS_FILE}"
rm -f "${AZURE_CREDS_FILE}"

echo "Pre-creating/annotating the 'velero' ServiceAccount for Workload Identity (must exist with this annotation before the DPA triggers Velero pod creation)..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: velero
  namespace: openshift-adp
  annotations:
    azure.workload.identity/client-id: "${OADP_MI_CLIENT_ID}"
EOF

echo "OADP workload identity setup complete"

# Create DataProtectionApplication
echo "Creating DataProtectionApplication..."
cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-instance
  namespace: openshift-adp
spec:
  backupImages: false
  configuration:
    nodeAgent:
      enable: true
      uploaderType: kopia
      podConfig:
        labels:
          azure.workload.identity/use: "true"
    velero:
      customPlugins:
        - name: hypershift-oadp-plugin
          image: ${OADP_PLUGIN_IMAGE}
      defaultPlugins:
        - openshift
        - azure
        - csi
      disableFsBackup: false
      resourceTimeout: 2h
      noDefaultBackupLocation: true
      logLevel: debug
      podConfig:
        labels:
          azure.workload.identity/use: "true"
EOF

# Wait for Velero pod to be ready
echo "Waiting for Velero pod to be ready..."
oc wait --for=condition=Available deployment/velero -n openshift-adp --timeout=300s

# Safety net: the OADP operator's own ServiceAccount reconcile could in
# principle recreate/strip the annotation we pre-set above, or the very first
# Velero/NodeAgent pod could have raced the webhook. Re-assert the annotation
# and, if it was missing, force a rollout so the webhook mutates fresh pods.
echo "Verifying 'velero' ServiceAccount annotation survived DPA reconcile..."
CURRENT_CLIENT_ID="$(oc get sa velero -n openshift-adp -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}' 2>/dev/null || true)"
if [[ "${CURRENT_CLIENT_ID}" != "${OADP_MI_CLIENT_ID}" ]]; then
  echo "Annotation missing or stale (got '${CURRENT_CLIENT_ID}'), re-annotating and restarting Velero/NodeAgent..."
  oc annotate serviceaccount velero -n openshift-adp \
    "azure.workload.identity/client-id=${OADP_MI_CLIENT_ID}" --overwrite
  oc rollout restart deployment/velero -n openshift-adp
  oc rollout status deployment/velero -n openshift-adp --timeout=300s
  if oc get daemonset/node-agent -n openshift-adp >/dev/null 2>&1; then
    oc rollout restart daemonset/node-agent -n openshift-adp
    oc rollout status daemonset/node-agent -n openshift-adp --timeout=300s
  fi
fi

# Create BackupStorageLocation
echo "Creating BackupStorageLocation..."
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: openshift-adp
spec:
  provider: azure
  objectStorage:
    bucket: ${CONTAINER_NAME}
    prefix: backup-objects
  credential:
    name: cloud-credentials
    key: cloud
  config:
    resourceGroup: ${RESOURCEGROUP}
    storageAccount: ${STORAGE_ACCOUNT_NAME}
    useAAD: "true"
EOF

# Create VolumeSnapshotLocation
# NOTE (open risk, unverified): this reuses the same Workload-Identity-shaped
# cloud-credentials Secret, but the identity currently only holds "Storage
# Blob Data Contributor" on the storage account. If Velero's Azure
# volumesnapshotter plugin (as opposed to the "csi" plugin's
# VolumeSnapshotClass path) performs ARM disk-snapshot calls with this
# identity, it will likely need a separate role (e.g. "Disk Snapshot
# Contributor" or "Contributor") scoped to the resource group holding the
# guest cluster's managed disks. Verify against an actual backup/restore run;
# add the role assignment above if AuthorizationFailed errors appear on VSL
# snapshot operations.
echo "Creating VolumeSnapshotLocation..."
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: VolumeSnapshotLocation
metadata:
  name: ${CLUSTER_NAME}
  namespace: openshift-adp
spec:
  provider: azure
  credential:
    name: cloud-credentials
    key: cloud
  config:
    resourceGroup: ${RESOURCEGROUP}
EOF

echo "OADP setup complete"
