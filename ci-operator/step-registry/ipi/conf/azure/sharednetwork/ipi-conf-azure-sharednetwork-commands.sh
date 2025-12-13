#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [ -f "${SHARED_DIR}/customer_vnet_subnets.yaml" ]; then
  PATCH="${SHARED_DIR}/customer_vnet_subnets.yaml"
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
