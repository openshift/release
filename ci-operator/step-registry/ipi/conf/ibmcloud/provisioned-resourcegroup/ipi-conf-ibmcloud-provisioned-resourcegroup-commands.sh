#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


if [[ -s "${SHARED_DIR}/ibmcloud_cluster_resource_group" ]]; then
    provisioned_rg_file="${SHARED_DIR}/ibmcloud_cluster_resource_group"
else
    provisioned_rg_file="${SHARED_DIR}/ibmcloud_resource_group"
fi

if [ ! -f "${provisioned_rg_file}" ]; then
    echo "${provisioned_rg_file} is not found, exiting..."
    exit 1
fi

provisioned_rg=$(cat "${provisioned_rg_file}")
echo "Using provisioned resource group: ${provisioned_rg}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-provisioned-resourcegroup.yaml.patch"

# create a patch with existing resource group configuration
cat > "${PATCH}" << EOF
platform:
  ibmcloud:
    resourceGroupName: ${provisioned_rg}
EOF

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"
