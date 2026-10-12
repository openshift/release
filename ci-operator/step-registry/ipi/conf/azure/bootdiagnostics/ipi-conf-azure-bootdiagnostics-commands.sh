#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "controlPlane boot diagnostics type: ${AZURE_CONTROL_PLANE_BOOT_DIAGNOSTICS_TYPE}"
echo "Compute boot diagnostics type: ${AZURE_COMPUTE_BOOT_DIAGNOSTICS_TYPE}"
echo "DefaultMachinePlatform boot diagnostics type: ${AZURE_DEFAULT_MACHINE_BOOT_DIAGNOSTICS_TYPE}"

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ -f "${SHARED_DIR}/azure_storage_account_name" ]]; then
    sa_name=$(< "${SHARED_DIR}/azure_storage_account_name")
fi

if [[ -f "${SHARED_DIR}/resourcegroup_sa" ]]; then
    sa_resource_group=$(< "${SHARED_DIR}/resourcegroup_sa")
fi

# Set boot diagnostics type for control plane nodes
CONFIG_PATCH="${SHARED_DIR}/install-config-azure-boot-diagnostics-type.yaml.patch"
if [[ -n "${AZURE_CONTROL_PLANE_BOOT_DIAGNOSTICS_TYPE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  platform:
    azure:
      bootDiagnostics:
        type: ${AZURE_CONTROL_PLANE_BOOT_DIAGNOSTICS_TYPE}
EOF
    if [[ "${AZURE_CONTROL_PLANE_BOOT_DIAGNOSTICS_TYPE}" == "UserManaged" ]]; then
        cat >> "${CONFIG_PATCH}" << EOF
        storageAccountName: ${sa_name}
        resourceGroup: ${sa_resource_group}
EOF
    fi
fi

#Set boot diagnostics type for compute nodes
if [[ -n "${AZURE_COMPUTE_BOOT_DIAGNOSTICS_TYPE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- platform:
    azure:
      bootDiagnostics:
        type: ${AZURE_COMPUTE_BOOT_DIAGNOSTICS_TYPE}
EOF
    if [[ "${AZURE_COMPUTE_BOOT_DIAGNOSTICS_TYPE}" == "UserManaged" ]]; then
        cat >> "${CONFIG_PATCH}" << EOF
        storageAccountName: ${sa_name}
        resourceGroup: ${sa_resource_group}
EOF
    fi
fi

# Set boot diagnostics type under defaultMachinePlatform, applied to all nodes
if [[ -n "${AZURE_DEFAULT_MACHINE_BOOT_DIAGNOSTICS_TYPE}" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
platform:
  azure:
    defaultMachinePlatform:
      bootDiagnostics:
        type: ${AZURE_DEFAULT_MACHINE_BOOT_DIAGNOSTICS_TYPE}
EOF
    if [[ "${AZURE_DEFAULT_MACHINE_BOOT_DIAGNOSTICS_TYPE}" == "UserManaged" ]]; then
        cat >> "${CONFIG_PATCH}" << EOF
        storageAccountName: ${sa_name}
        resourceGroup: ${sa_resource_group}
EOF
    fi
fi

if [[ -s "${CONFIG_PATCH}" ]]; then
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
    echo "Debug - patch content"
    cat "${CONFIG_PATCH}"
fi
