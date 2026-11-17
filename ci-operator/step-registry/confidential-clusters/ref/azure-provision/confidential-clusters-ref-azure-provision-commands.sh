#!/bin/bash
set -euo pipefail

suffix=$(uuidgen | head -c8)
echo "${suffix}" > "${SHARED_DIR}/cocl-suffix"

# The cluster's actual region may differ from LEASED_RESOURCE if a region
# override step ran during cluster installation
if [[ -f "${SHARED_DIR}/azure-region" ]]; then
  region=$(<"${SHARED_DIR}/azure-region")
else
  region="${LEASED_RESOURCE}"
fi

resource_group="cocl-scale-test-${suffix}"
storage_account="coclscaletest${suffix}"
container="cocl-scale-test-${suffix}"
gallery="cocl_scale_test_${suffix}"
image_definition="cocl-scale-test-${suffix}"
image_version="0.0.1"

echo "${resource_group}" > "${SHARED_DIR}/cocl-resourcegroup"

echo "Logging in with the azure-qe service principal to fetch the test image"
azure_qe_client_id=$(jq -r .clientId /tmp/secrets/azure-qe/osServicePrincipal.json)
azure_qe_client_secret=$(jq -r .clientSecret /tmp/secrets/azure-qe/osServicePrincipal.json)
azure_qe_tenant_id=$(jq -r .tenantId /tmp/secrets/azure-qe/osServicePrincipal.json)
az login --service-principal \
  -u "${azure_qe_client_id}" \
  -p "${azure_qe_client_secret}" \
  --tenant "${azure_qe_tenant_id}" \
  --output none

src_image=$(cat /tmp/secrets/azure-qe/cocl-test-image)
src_account="${src_image%%/*}"
src_remainder="${src_image#*/}"
src_container="${src_remainder%%/*}"
src_blob="${src_remainder#*/}"
local_blob=/tmp/cocl-test-image-blob

echo "Downloading ${src_blob} from ${src_account}/${src_container}"
az storage blob download \
  --account-name "${src_account}" \
  --container-name "${src_container}" \
  --name "${src_blob}" \
  --file "${local_blob}" \
  --auth-mode login \
  --output none \
  --no-progress

echo "Logging in to the leased Azure subscription to create test resources"
client_id=$(jq -r .clientId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
client_secret=$(jq -r .clientSecret "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
tenant_id=$(jq -r .tenantId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
subscription_id=$(jq -r .subscriptionId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
az login --service-principal \
  -u "${client_id}" \
  -p "${client_secret}" \
  --tenant "${tenant_id}" \
  --output none
az account set --subscription "${subscription_id}"

echo "Creating resource group ${resource_group}"
az group create --name "${resource_group}" --location "${region}" --output none

echo "Creating storage account ${storage_account}"
az storage account create \
  --resource-group "${resource_group}" \
  --name "${storage_account}" \
  --location "${region}" \
  --kind StorageV2 \
  --sku Standard_LRS \
  --output none

[[ $- == *x* ]] && was_tracing=true || was_tracing=false
set +x
connection_string=$(az storage account show-connection-string \
  --resource-group "${resource_group}" \
  --name "${storage_account}" \
  --query connectionString --output tsv)

echo "Creating container ${container}"
az storage container create \
  --connection-string "${connection_string}" \
  --name "${container}" \
  --output none

echo "Uploading ${src_blob} to ${storage_account}/${container}"
az storage blob upload \
  --connection-string "${connection_string}" \
  --container-name "${container}" \
  --file "${local_blob}" \
  --name "${src_blob}" \
  --type page `# For VHDs, it is supposed to default to page, but is required explicitly here` \
  --no-progress
${was_tracing} && set -x

echo "Creating compute gallery ${gallery}"
az sig create \
  --resource-group "${resource_group}" \
  --gallery-name "${gallery}" \
  --output none

echo "Creating image definition ${image_definition}"
az sig image-definition create \
  --resource-group "${resource_group}" \
  --gallery-name "${gallery}" \
  --gallery-image-definition "${image_definition}" \
  --publisher example --offer example --sku standard \
  --features SecurityType=ConfidentialVmSupported \
  --os-type Linux --hyper-v-generation V2 \
  --output none

echo "Creating image version ${image_version}"
az sig image-version create \
  --resource-group "${resource_group}" \
  --gallery-name "${gallery}" \
  --gallery-image-definition "${image_definition}" \
  --gallery-image-version "${image_version}" \
  --os-vhd-storage-account "/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Storage/storageAccounts/${storage_account}" \
  --os-vhd-uri "https://${storage_account}.blob.core.windows.net/${container}/${src_blob}" \
  --output none

azure_resource_id="/resourceGroups/${resource_group}/providers/Microsoft.Compute/galleries/${gallery}/images/${image_definition}/versions/${image_version}"
echo "${azure_resource_id}" > "${SHARED_DIR}/cocl-azure-resource-id"
echo "Created image version: ${azure_resource_id}"
