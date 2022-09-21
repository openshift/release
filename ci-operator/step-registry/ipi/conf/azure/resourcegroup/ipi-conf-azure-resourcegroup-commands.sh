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

# create a patch with existing resource group configuration
cat > "${PATCH}" << EOF
platform:
  azure:
    resourceGroupName: ${existing_rg}
EOF

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"
