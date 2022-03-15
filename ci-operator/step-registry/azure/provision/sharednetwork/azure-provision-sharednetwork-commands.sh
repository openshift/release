#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/v4.22.1/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

# get vnet_name, compute and controlPlane subnet values
vnet_name=$(cat ${SHARED_DIR}/customer_vnet_subnets.yaml | /tmp/yq '.platform.azure.virtualNetwork')
controlPlaneSubnet=$(cat ${SHARED_DIR}/customer_vnet_subnets.yaml | /tmp/yq '.platform.azure.controlPlaneSubnet')
computeSubnet=$(cat ${SHARED_DIR}/customer_vnet_subnets.yaml | /tmp/yq '.platform.azure.computeSubnet')

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-qe-sharednetwork.yaml.patch"

cat >> "${PATCH}" << EOF
platform:
  azure:
    networkResourceGroupName: os4-common
    virtualNetwork: ${vnet_name}
    controlPlaneSubnet: ${controlPlaneSubnet}
    computeSubnet: ${computeSubnet}
EOF

/tmp/yq ea -i "${CONFIG}" "${PATCH}"

echo "$(cat ${CONFIG})"
