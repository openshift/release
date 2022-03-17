#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/v4.22.1/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"

if [ -f "${SHARED_DIR}/customer_vnet_subnets.yaml" ]; then
  vnet_name=$(cat ${SHARED_DIR}/customer_vnet_subnets.yaml | /tmp/yq '.platform.azure.virtualNetwork')
  controlPlaneSubnet=$(cat ${SHARED_DIR}/customer_vnet_subnets.yaml | /tmp/yq '.platform.azure.controlPlaneSubnet')
  computeSubnet=$(cat ${SHARED_DIR}/customer_vnet_subnets.yaml | /tmp/yq '.platform.azure.computeSubnet')
  
  PATCH="${SHARED_DIR}/install-config-qe-sharednetwork.yaml.patch"

  cat >> "${PATCH}" << EOF
platform:
  azure:
    networkResourceGroupName: os4-common
    virtualNetwork: ${vnet_name}
    controlPlaneSubnet: ${controlPlaneSubnet}
    computeSubnet: ${computeSubnet}
EOF
else
  PATCH=/tmp/install-config-sharednetwork.yaml.patch

  azure_region=$(/tmp/yq r "${CONFIG}" 'platform.azure.region')

  cat > "${PATCH}" << EOF
platform:
  azure:
    networkResourceGroupName: os4-common
    virtualNetwork: do-not-delete-shared-vnet-${azure_region}
    controlPlaneSubnet: subnet-1
    computeSubnet: subnet-2
EOF
fi
/tmp/yq ea -i "${CONFIG}" "${PATCH}"
