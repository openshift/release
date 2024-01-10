#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "controlPlane disk type: ${AZURE_CONTROL_PLANE_DISK_TYPE}"
echo "Compute disk type: ${AZURE_CONTROL_PLANE_DISK_TYPE}"
echo "DefaultMachinePlatform disk type: ${AZURE_DEFAULT_MACHINE_DISK_TYPE}"

# Set disk type for control plane nodes
CONFIG_PATCH="${SHARED_DIR}/install-config-azure-disk-type.yaml.patch"
if [[ -n "${AZURE_CONTROL_PLANE_DISK_TYPE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    azure:
      osDisk:
        diskType: ${AZURE_CONTROL_PLANE_DISK_TYPE}
EOF
fi

#Set disk type for compute nodes
if [[ -n "${AZURE_COMPUTE_DISK_TYPE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- platform:
    azure:
      osDisk:
        diskType: ${AZURE_COMPUTE_DISK_TYPE}
EOF
fi

# Set disk type under defaultMachinePlatform, applied to all nodes
if [[ -n "${AZURE_DEFAULT_MACHINE_DISK_TYPE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      osDisk:
        diskType: ${AZURE_DEFAULT_MACHINE_DISK_TYPE}
EOF
fi

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

cat "${CONFIG_PATCH}"
