#!/bin/bash

# WARNING:This script must be run after installing the hosted cluster.
# The SCC crds from this script are required for Velero and Node Agent
# to run but then, HostedCluster on AKS fails to start. Some pods from
# HCP namespace fail with "container has runAsNonRoot and image will run as root"

set -euo pipefail

VELERO_VERSION="${VELERO_VERSION:-v1.18.0}"
VELERO_NAMESPACE="openshift-adp"
RESOURCEGROUP_AKS="$(cat "${SHARED_DIR}/resourcegroup_aks")"
AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
OADP_HYPERSHIFT_PLUGIN_IMAGE="${OADP_HYPERSHIFT_PLUGIN_IMAGE:-quay.io/redhat-user-workloads/ocp-art-tenant/oadp-hypershift-oadp-plugin-main:main}"
OADP_AZURE_PLUGIN_IMAGE="${OADP_AZURE_PLUGIN_IMAGE:-quay.io/konveyor/velero-plugin-for-microsoft-azure:oadp-1.5}"

echo "Logging into Azure..."
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
BUCKET_NAME="${OADP_AZURE_BUCKET_NAME:-hypershift-oadp-${CLUSTER_NAME}}"
# Create storage account with a unique name (max 24 chars, lowercase alphanumeric)
STORAGE_ACCOUNT_NAME="oadp${CLUSTER_NAME:0:20}"
STORAGE_ACCOUNT_NAME="$(echo "${STORAGE_ACCOUNT_NAME}" | tr -cd '[:lower:][:digit:]' | cut -c1-24)"

echo "Creating storage account ${STORAGE_ACCOUNT_NAME} in resource group ${RESOURCEGROUP_AKS}..."
az storage account create \
  --name "${STORAGE_ACCOUNT_NAME}" \
  --resource-group "${RESOURCEGROUP_AKS}" \
  --location "${HYPERSHIFT_AZURE_LOCATION:-eastus2}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --output none

echo "${STORAGE_ACCOUNT_NAME}" > "${SHARED_DIR}/oadp-storage-account-name"

echo "Creating blob container ${BUCKET_NAME}..."
az storage container create \
  --name "${BUCKET_NAME}" \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --output none

echo "Getting storage account key..."
STORAGE_ACCOUNT_KEY="$(az storage account keys list --account-name "${STORAGE_ACCOUNT_NAME}" --resource-group "${RESOURCEGROUP_AKS}" --query '[0].value' -o tsv)"

echo "Creating Azure credentials secret..."
AZURE_CREDS_FILE="$(mktemp)"
cat <<EOF > "${AZURE_CREDS_FILE}"
AZURE_SUBSCRIPTION_ID=${AZURE_AUTH_SUBSCRIPTION_ID}
AZURE_TENANT_ID=${AZURE_AUTH_TENANT_ID}
AZURE_CLIENT_ID=${AZURE_AUTH_CLIENT_ID}
AZURE_CLIENT_SECRET=${AZURE_AUTH_CLIENT_SECRET}
AZURE_RESOURCE_GROUP=${RESOURCEGROUP_AKS}
AZURE_STORAGE_ACCOUNT_ACCESS_KEY=${STORAGE_ACCOUNT_KEY}
EOF

wget https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz -O /tmp/velero.tar.gz
tar -xzf /tmp/velero.tar.gz -C /tmp
export PATH=/tmp/velero-${VELERO_VERSION}-linux-amd64:$PATH

velero install --image quay.io/konveyor/velero:latest \
  --namespace "${VELERO_NAMESPACE}" \
  --plugins "${OADP_AZURE_PLUGIN_IMAGE}","${OADP_HYPERSHIFT_PLUGIN_IMAGE}" \
  --no-default-backup-location \
  --secret-file "${AZURE_CREDS_FILE}" \
  --use-volume-snapshots=false \
  --use-node-agent

velero backup-location create "${CLUSTER_NAME}" \
  --namespace "${VELERO_NAMESPACE}" \
  --provider azure \
  --bucket "${BUCKET_NAME}" \
  --config resourceGroup="${RESOURCEGROUP_AKS}",storageAccount="${STORAGE_ACCOUNT_NAME}",subscriptionId="${AZURE_AUTH_SUBSCRIPTION_ID}"

echo "Waiting for velero Deployment to be ready..."
oc rollout status deployment/velero -n "${VELERO_NAMESPACE}" --timeout=300s

# Setup VolumeSnapshotClass for Azure Disk CSI Driver.
# Create VolumeSnapshotClass when using --features=EnableCSI for velero
# cat <<EOF | oc apply -f -
# apiVersion: snapshot.storage.k8s.io/v1
# kind: VolumeSnapshotClass
# metadata:
#   name: azure-disk-csi-snapclass
#   labels:
#     velero.io/csi-volumesnapshot-class: "true"
# driver: disk.csi.azure.com
# deletionPolicy: Retain
# EOF

echo "OADP setup complete"
