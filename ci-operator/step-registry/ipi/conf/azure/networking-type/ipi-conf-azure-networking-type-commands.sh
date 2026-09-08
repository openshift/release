#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "controlPlane networking type: ${AZURE_CONTROL_PLANE_NETWORKING_TYPE}"
echo "Compute networking type: ${AZURE_COMPUTE_NETWORKING_TYPE}"
echo "DefaultMachinePlatform networking type: ${AZURE_DEFAULT_MACHINE_NETWORKING_TYPE}"

CONFIG="${SHARED_DIR}/install-config.yaml"

# Set networking type for control plane nodes
CONFIG_PATCH="${SHARED_DIR}/install-config-azure-networking-type.yaml.patch"
if [[ -n "${AZURE_CONTROL_PLANE_NETWORKING_TYPE}" ]]; then
    cat > "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    azure:
      vmNetworkingType: ${AZURE_CONTROL_PLANE_NETWORKING_TYPE}
EOF
fi

#Set networking type for compute nodes
if [[ -n "${AZURE_COMPUTE_NETWORKING_TYPE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- platform:
    azure:
      vmNetworkingType: ${AZURE_COMPUTE_NETWORKING_TYPE}
EOF
fi

# Set networking type under defaultMachinePlatform, applied to all nodes
if [[ -n "${AZURE_DEFAULT_MACHINE_NETWORKING_TYPE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      vmNetworkingType: ${AZURE_DEFAULT_MACHINE_NETWORKING_TYPE}
EOF
fi

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

cat "${CONFIG_PATCH}"
