#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [ -f "${SHARED_DIR}/customer_vnet_subnets.yaml" ]; then
  VNET_FILE="${SHARED_DIR}/customer_vnet_subnets.yaml"
  RESOURCE_GROUP=$(cat ${SHARED_DIR}/resourcegroup)
  vnet_name=$(yq-go r ${VNET_FILE} 'platform.azure.virtualNetwork')
  controlPlaneSubnet=$(yq-go r ${VNET_FILE} 'platform.azure.controlPlaneSubnet')
  computeSubnet=$(yq-go r ${VNET_FILE} 'platform.azure.computeSubnet')

  PATCH="${SHARED_DIR}/install-config-provisioned-sharednetwork.yaml.patch"

  cat >> "${PATCH}" << EOF
platform:
  azure:
    networkResourceGroupName: ${RESOURCE_GROUP}
    virtualNetwork: ${vnet_name}
    controlPlaneSubnet: ${controlPlaneSubnet}
    computeSubnet: ${computeSubnet}
EOF
else
  PATCH=/tmp/install-config-sharednetwork.yaml.patch

  azure_region=$(yq-go r "${CONFIG}" 'platform.azure.region')

  cat > "${PATCH}" << EOF
platform:
  azure:
    networkResourceGroupName: os4-common
    virtualNetwork: do-not-delete-shared-vnet-${azure_region}
    controlPlaneSubnet: subnet-1
    computeSubnet: subnet-2
EOF
fi
yq-go m -x -i "${CONFIG}" "${PATCH}"
