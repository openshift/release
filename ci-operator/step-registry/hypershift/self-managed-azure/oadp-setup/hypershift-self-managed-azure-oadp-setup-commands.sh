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
CLUSTER_NAME="$(oc get hostedcluster -n clusters -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "${CLUSTER_PREFIX}" | head -n1)"
if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "!!! Unable to find a public HostedCluster in the 'clusters' namespace"
  oc get hostedcluster -n clusters
  exit 1
fi
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

RESOURCEGROUP="$(cat "${SHARED_DIR}/azure_pls_resource_group")"
CONTAINER_NAME="${OADP_AZURE_CONTAINER_NAME:-hypershift-oadp-${CLUSTER_NAME}}"
# Storage account names must be 3-24 chars, lowercase letters and numbers only.
STORAGE_ACCOUNT_NAME="oadp${CLUSTER_NAME:0:20}"
STORAGE_ACCOUNT_NAME="$(echo "${STORAGE_ACCOUNT_NAME}" | tr -cd '[:lower:][:digit:]' | cut -c1-24)"

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

echo "Getting storage account key..."
STORAGE_ACCOUNT_KEY="$(az storage account keys list --account-name "${STORAGE_ACCOUNT_NAME}" --resource-group "${RESOURCEGROUP}" --query '[0].value' -o tsv)"

# Create the openshift-adp namespace if it doesn't exist
oc get namespace openshift-adp 2>/dev/null || oc create namespace openshift-adp

echo "Creating Azure credentials secret..."
# Disable tracing due to credential handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

AZURE_CREDS_FILE="$(mktemp)"
cat <<EOF > "${AZURE_CREDS_FILE}"
AZURE_SUBSCRIPTION_ID=${AZURE_AUTH_SUBSCRIPTION_ID}
AZURE_TENANT_ID=${AZURE_AUTH_TENANT_ID}
AZURE_CLIENT_ID=${AZURE_AUTH_CLIENT_ID}
AZURE_CLIENT_SECRET=${AZURE_AUTH_CLIENT_SECRET}
AZURE_RESOURCE_GROUP=${RESOURCEGROUP}
AZURE_CLOUD_NAME=AzurePublicCloud
AZURE_STORAGE_ACCOUNT_ACCESS_KEY=${STORAGE_ACCOUNT_KEY}
EOF

oc create secret generic cloud-credentials -n openshift-adp --from-file cloud="${AZURE_CREDS_FILE}"
rm -f "${AZURE_CREDS_FILE}"

$WAS_TRACING && set -x

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
EOF

# Wait for Velero pod to be ready
echo "Waiting for Velero pod to be ready..."
oc wait --for=condition=Available deployment/velero -n openshift-adp --timeout=300s || true

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
EOF

# Create VolumeSnapshotLocation
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
