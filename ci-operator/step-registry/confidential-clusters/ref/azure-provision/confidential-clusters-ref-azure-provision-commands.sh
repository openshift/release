#!/bin/bash
set -euo pipefail

SUFFIX=$(uuidgen | tr -d '-' | head -c 8)
echo "${SUFFIX}" > "${SHARED_DIR}/cocl-suffix"

RESOURCE_GROUP="cocl-scale-test-${SUFFIX}"
STORAGE_ACCOUNT="coclscaletest${SUFFIX}"
CONTAINER="cocl-scale-test-${SUFFIX}"
# Compute gallery names cannot contain hyphens.
GALLERY="cocl_scale_test_${SUFFIX}"
IMAGE_DEFINITION="cocl-scale-test-${SUFFIX}"
IMAGE_VERSION="0.0.1"

# Written now so the cleanup post-step can find the resource group even if
# this step fails partway through or times out.
echo "${RESOURCE_GROUP}" > "${SHARED_DIR}/cocl-resourcegroup"

# Disable tracing while service principal credentials are read/used.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

echo "Logging in with the trusted-execution-clusters-azure service principal to fetch the test image"
az login --service-principal \
  -u "$(cat /tmp/secrets/azure/client-id)" \
  -p "$(cat /tmp/secrets/azure/client-secret)" \
  --tenant "$(cat /tmp/secrets/azure/tenant-id)" \
  --output none

${WAS_TRACING} && set -x

SRC_IMAGE="downstreamci/cos/redhat-coreos-9.6.20260112-0-azure-ovf-accept35-v2.x86_64.vhd"
SRC_ACCOUNT="${SRC_IMAGE%%/*}"
SRC_REST="${SRC_IMAGE#*/}"
SRC_CONTAINER="${SRC_REST%%/*}"
SRC_BLOB="${SRC_REST#*/}"
LOCAL_BLOB=/tmp/cocl-test-image-blob

echo "Downloading ${SRC_BLOB} from ${SRC_ACCOUNT}/${SRC_CONTAINER}"
az storage blob download \
  --account-name "${SRC_ACCOUNT}" \
  --container-name "${SRC_CONTAINER}" \
  --name "${SRC_BLOB}" \
  --file "${LOCAL_BLOB}" \
  --auth-mode login \
  --output none

[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

echo "Logging in to the leased Azure subscription to create test resources"
CLIENT_ID=$(jq -r .clientId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
CLIENT_SECRET=$(jq -r .clientSecret "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
TENANT_ID=$(jq -r .tenantId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
SUBSCRIPTION_ID=$(jq -r .subscriptionId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
az login --service-principal \
  -u "${CLIENT_ID}" \
  -p "${CLIENT_SECRET}" \
  --tenant "${TENANT_ID}" \
  --output none
az account set --subscription "${SUBSCRIPTION_ID}"

${WAS_TRACING} && set -x

echo "Creating resource group ${RESOURCE_GROUP}"
az group create --name "${RESOURCE_GROUP}" --location "${AZURE_REGION}" --output none

echo "Creating storage account ${STORAGE_ACCOUNT}"
az storage account create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${STORAGE_ACCOUNT}" \
  --location "${AZURE_REGION}" \
  --kind Storage \
  --sku Standard_LRS \
  --output none

[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
CONNECTION_STRING=$(az storage account show-connection-string \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${STORAGE_ACCOUNT}" \
  --query connectionString --output tsv)
${WAS_TRACING} && set -x

echo "Creating container ${CONTAINER}"
az storage container create \
  --connection-string "${CONNECTION_STRING}" \
  --name "${CONTAINER}" \
  --output none

echo "Uploading ${SRC_BLOB} to ${STORAGE_ACCOUNT}/${CONTAINER}"
az storage blob upload \
  --connection-string "${CONNECTION_STRING}" \
  --container-name "${CONTAINER}" \
  --file "${LOCAL_BLOB}" \
  --name "${SRC_BLOB}" \
  --output none

echo "Creating compute gallery ${GALLERY}"
az sig create \
  --resource-group "${RESOURCE_GROUP}" \
  --gallery-name "${GALLERY}" \
  --output none

echo "Creating image definition ${IMAGE_DEFINITION}"
az sig image-definition create \
  --resource-group "${RESOURCE_GROUP}" \
  --gallery-name "${GALLERY}" \
  --gallery-image-definition "${IMAGE_DEFINITION}" \
  --publisher example --offer example --sku standard \
  --features SecurityType=ConfidentialVmSupported \
  --os-type Linux --hyper-v-generation V2 \
  --output none

echo "Creating image version ${IMAGE_VERSION}"
az sig image-version create \
  --resource-group "${RESOURCE_GROUP}" \
  --gallery-name "${GALLERY}" \
  --gallery-image-definition "${IMAGE_DEFINITION}" \
  --gallery-image-version "${IMAGE_VERSION}" \
  --os-vhd-storage-account "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}" \
  --os-vhd-uri "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${SRC_BLOB}" \
  --output none

AZURE_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${GALLERY}/images/${IMAGE_DEFINITION}/versions/${IMAGE_VERSION}"
echo "${AZURE_RESOURCE_ID}" > "${SHARED_DIR}/cocl-azure-resource-id"
echo "Created image version: ${AZURE_RESOURCE_ID}"
