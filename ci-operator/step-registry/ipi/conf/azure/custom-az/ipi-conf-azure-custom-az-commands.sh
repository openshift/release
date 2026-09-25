#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "controlPlane Azure custom zones: ${CP_CUSTOM_AZURE_AZ}"
echo "Compute Azure custom zones: ${COMPUTE_CUSTOM_AZURE_AZ}"

CONFIG_PATCH="${SHARED_DIR}/install-config-zones.yaml.patch"
if [[ -n "${CP_CUSTOM_AZURE_AZ}" ]]; then
    cat > "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    azure:
      zones: ${CP_CUSTOM_AZURE_AZ}
EOF
fi
if [[ -n "${COMPUTE_CUSTOM_AZURE_AZ}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- platform:
    azure:
      zones: ${COMPUTE_CUSTOM_AZURE_AZ}
EOF
fi
if [[ -s "${CONFIG_PATCH}" ]]; then
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
    echo "CONFIG_PATCH content:"
    cat ${CONFIG_PATCH}
else
    echo "CONFIG_PATCH is empty, skip the setting in install-config!"
fi
