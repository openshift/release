#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "controlPlane Azure custom zones: ${CP_CUSTOM_AZURE_AZ}"
echo "Compute Azure custom zones: ${COMPUTE_CUSTOM_AZURE_AZ}"

CONFIG_PATCH="${SHARED_DIR}/install-config-zones.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    azure:
      zones: ${CP_CUSTOM_AZURE_AZ}
compute:
- platform:
    azure:
      zones: ${COMPUTE_CUSTOM_AZURE_AZ}
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
