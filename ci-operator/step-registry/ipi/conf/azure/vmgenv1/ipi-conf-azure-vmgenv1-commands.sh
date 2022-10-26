#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-existingvmgenv1.yaml.patch"
# the only vm instance type which HyperVGenerations is 'V1', with it, can create the vm which generation is V1.
azure_region="southcentralus"
vm_type="Standard_NP10s"

# az should already be there
command -v az

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

# create a patch with existing resource group configuration
cat > "${PATCH}" << EOF
compute:
- platform:
    azure:
      type: ${vm_type}
controlPlane:
  platform:
    azure:
      type: ${vm_type}
platform:
  azure:
    region: ${azure_region}
EOF

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"
