#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-existingresourcegroup.yaml.patch"

azure_region=$(yq-go r "${CONFIG}" 'platform.azure.region')
cluster_name=$(yq-go r "${CONFIG}" 'metadata.name')
existing_rg=${cluster_name}-exrg

# az should already be there
command -v az

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

# create resource group prior to installation
az group create -l "${azure_region}" -n "${existing_rg}"

# Assigne proper permissions to resource group where cluster will be created
if [[ -n "${AZURE_PERMISSION_FOR_CLUSTER_RG}" ]]; then
    cluster_sp_id=${AZURE_AUTH_CLIENT_ID}
    if [[ -f "${SHARED_DIR}/azure_sp_id" ]]; then
        cluster_sp_id=$(< "${SHARED_DIR}/azure_sp_id")
    fi
    resource_group_id=$(az group show -g "${existing_rg}" --query id -otsv)
    echo "Assigin role '${AZURE_PERMISSION_FOR_CLUSTER_RG}' to resource group ${existing_rg}"
    az role assignment create --assignee ${cluster_sp_id} --role "${AZURE_PERMISSION_FOR_CLUSTER_RG}" --scope ${resource_group_id} -o jsonc
fi

# create a patch with existing resource group configuration
cat > "${PATCH}" << EOF
platform:
  azure:
    resourceGroupName: ${existing_rg}
EOF

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"
