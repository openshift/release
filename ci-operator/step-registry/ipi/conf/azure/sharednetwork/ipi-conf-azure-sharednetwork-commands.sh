#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-sharednetwork.yaml.patch"

azure_region=$(/tmp/yq r "${CONFIG}" 'platform.azure.region')

cat >> "${PATCH}" << EOF
platform:
  azure:
    networkResourceGroupName: os4-common
    virtualNetwork: do-not-delete-shared-vnet-${azure_region}
    controlPlaneSubnet: subnet-1
    computeSubnet: subnet-2
EOF

/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
