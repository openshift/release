#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "controlPlane disk size: ${AZURE_CONTROL_PLANE_DISK_SIZE}"
echo "Compute disk size: ${AZURE_CONTROL_PLANE_DISK_SIZE}"
echo "DefaultMachinePlatform disk size: ${AZURE_DEFAULT_MACHINE_DISK_SIZE}"

# Set disk size for control plane nodes
CONFIG_PATCH="${SHARED_DIR}/install-config-azure-disk-size.yaml.patch"
if [[ -n "${AZURE_CONTROL_PLANE_DISK_SIZE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    azure:
      osDisk:
        diskSizeGB: ${AZURE_CONTROL_PLANE_DISK_SIZE}
EOF
fi

#Set disk size for compute nodes
if [[ -n "${AZURE_COMPUTE_DISK_SIZE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- platform:
    azure:
      osDisk:
        diskSizeGB: ${AZURE_COMPUTE_DISK_SIZE}
EOF
fi

# Set disk size under defaultMachinePlatform, applied to all nodes
if [[ -n "${AZURE_DEFAULT_MACHINE_DISK_SIZE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      osDisk:
        diskSizeGB: ${AZURE_DEFAULT_MACHINE_DISK_SIZE}
EOF
fi

if [[ -f "${CONFIG_PATCH}" ]]; then
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
    cat "${CONFIG_PATCH}"
fi
