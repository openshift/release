#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "
controlPlane multi disk type: ${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}
    disk size: ${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}
    disk lun id: ${AZURE_CONTROL_PLANE_MULTIDISK_LUN_ID}
    disk caching type: ${AZURE_CONTROL_PLANE_MULTIDISK_CATCHING_TYPE}
    disk mount path (used for user-defined disk type): ${AZURE_CONTROL_PLANE_MULTIDISK_MOUNT_PATH}
compute multi disk type: ${AZURE_COMPUTE_MULTIDISK_TYPE}
    disk size: ${AZURE_COMPUTE_MULTIDISK_DISK_SIZE}
    disk lun id: ${AZURE_COMPUTE_MULTIDISK_LUN_ID}
    disk caching type: ${AZURE_COMPUTE_MULTIDISK_CATCHING_TYPE}
    disk mount path(used for user-defined disk type): ${AZURE_COMPUTE_MULTIDISK_STORAGE_ACCOUNT_TYPE}
"

# Set disk type for control plane nodes
CONFIG_PATCH="${SHARED_DIR}/install-config-azure-disk-type.yaml.patch"
if [[ "${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}" == "etcd" ]] || [[ "${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}" == "swap" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  diskSetup:
  - type: ${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}
    ${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}:
      platformDiskID: "${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}disk"
  platform:
    azure:
      dataDisks:
      - nameSuffix: ${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}disk
        diskSizeGB: ${AZURE_CONTROL_PLANE_MULTIDISK_DISK_SIZE}
        lun: ${AZURE_CONTROL_PLANE_MULTIDISK_LUN_ID}
EOF
fi

if [[ "${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}" == "user-defined" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  diskSetup:
  - type: ${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}
    userDefined:
      platformDiskID: "uddisk"
      mountPath: ${AZURE_CONTROL_PLANE_MULTIDISK_MOUNT_PATH}
  platform:
    azure:
      dataDisks:
      - nameSuffix: uddisk
        diskSizeGB: ${AZURE_CONTROL_PLANE_MULTIDISK_DISK_SIZE}
        lun: ${AZURE_CONTROL_PLANE_MULTIDISK_LUN_ID}
EOF
fi

# Set storage account type for control plane nodes data disk
if [[ -n "${AZURE_CONTROL_PLANE_MULTIDISK_STORAGE_ACCOUNT_TYPE}" ]]; then
    CONFIG_PATCH_SAT="$(mktemp)"
    cat > "${CONFIG_PATCH_SAT}" << EOF
controlPlane:
  platform:
    azure:
      dataDisks:
      - managedDisk: 
          storageAccountType: ${AZURE_CONTROL_PLANE_MULTIDISK_STORAGE_ACCOUNT_TYPE}
EOF
    yq-go m -x -i "${CONFIG_PATCH}" "${CONFIG_PATCH_SAT}"
fi

# Set disk encryption set for data disk on control plane nodes
if [[ -f "${SHARED_DIR}"/azure_des_id ]]; then
    CONFIG_PATCH_DES="$(mktemp)"
    cat > "${CONFIG_PATCH_DES}" << EOF
controlPlane:
  platform:
    azure:
      dataDisks:
      - managedDisk: 
          diskEncryptionSet:
            id: $(< "${SHARED_DIR}"/azure_des_id)
EOF
    yq-go m -x -i "${CONFIG_PATCH}" "${CONFIG_PATCH_DES}"
fi

# Set security encryption type for data disk on control plane nodes
if [[ -n "${AZURE_CONTROL_PLANE_MULTIDISK_SECURITY_ENCRYPTION_TYPE}" ]]; then
    CONFIG_PATCH_SET="$(mktemp)"
    cat >> "${CONFIG_PATCH_SET}" << EOF
controlPlane:
  platform:
    azure:
      dataDisks:
      - managedDisk: 
          securityProfile:
            securityEncryptionType: ${AZURE_CONTROL_PLANE_MULTIDISK_SECURITY_ENCRYPTION_TYPE}
EOF
    if [[ -f "${SHARED_DIR}"/azure_des_id ]]; then
        cat >> "${CONFIG_PATCH_SET}" << EOF
            diskEncryptionSet:
              id: $(< "${SHARED_DIR}"/azure_des_id)
EOF
    fi
    yq-go m -x -i "${CONFIG_PATCH}" "${CONFIG_PATCH_SET}"
fi

# Set disk type for compute nodes
if [[ "${AZURE_COMPUTE_MULTIDISK_TYPE}" == "etcd" ]] || [[ "${AZURE_COMPUTE_MULTIDISK_TYPE}" == "swap" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- diskSetup:
  - type: ${AZURE_COMPUTE_MULTIDISK_TYPE}
    ${AZURE_COMPUTE_MULTIDISK_TYPE}:
      platformDiskID: "${AZURE_COMPUTE_MULTIDISK_TYPE}disk"
  platform:
    azure:
      dataDisks:
      - nameSuffix: ${AZURE_COMPUTE_MULTIDISK_TYPE}disk
        diskSizeGB: ${AZURE_COMPUTE_MULTIDISK_DISK_SIZE}
        lun: ${AZURE_COMPUTE_MULTIDISK_LUN_ID}
EOF
fi

if [[ "${AZURE_COMPUTE_MULTIDISK_TYPE}" == "user-defined" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
compute:
- diskSetup:
  - type: ${AZURE_COMPUTE_MULTIDISK_TYPE}
    userDefined:
      platformDiskID: "uddisk"
      mountPath: ${AZURE_COMPUTE_MULTIDISK_MOUNT_PATH}
  platform:
    azure:
      dataDisks:
      - nameSuffix: uddisk
        diskSizeGB: ${AZURE_COMPUTE_MULTIDISK_DISK_SIZE}
        lun: ${AZURE_COMPUTE_MULTIDISK_LUN_ID}
EOF
fi

# Set storage account type for compute nodes data disk
if [[ -n "${AZURE_COMPUTE_MULTIDISK_STORAGE_ACCOUNT_TYPE}" ]]; then
    CONFIG_PATCH_SAT="$(mktemp)"
    cat > "${CONFIG_PATCH_SAT}" << EOF
compute:
- platform:
    azure:
      dataDisks:
      - managedDisk: 
          storageAccountType: ${AZURE_COMPUTE_MULTIDISK_STORAGE_ACCOUNT_TYPE}
EOF
    yq-go m -x -i "${CONFIG_PATCH}" "${CONFIG_PATCH_SAT}"
fi

# Set disk encryption set for data disk on compute nodes
if [[ -f "${SHARED_DIR}"/azure_des_id ]]; then
    CONFIG_PATCH_DES="$(mktemp)"
    cat > "${CONFIG_PATCH_DES}" << EOF
compute:
- platform:
    azure:
      dataDisks:
      - managedDisk: 
          diskEncryptionSet:
            id: $(< "${SHARED_DIR}"/azure_des_id)
EOF
    yq-go m -x -i "${CONFIG_PATCH}" "${CONFIG_PATCH_DES}"
fi

# Set security encryption type for data disk on compute nodes
if [[ -n "${AZURE_COMPUTE_MULTIDISK_SECURITY_ENCRYPTION_TYPE}" ]]; then
    CONFIG_PATCH_SET="$(mktemp)"
    cat >> "${CONFIG_PATCH_SET}" << EOF
compute:
- platform:
    azure:
      dataDisks:
      - managedDisk: 
          securityProfile:
            securityEncryptionType: ${AZURE_COMPUTE_MULTIDISK_SECURITY_ENCRYPTION_TYPE}
EOF
    if [[ -f "${SHARED_DIR}"/azure_des_id ]]; then
        cat >> "${CONFIG_PATCH_SET}" << EOF
            diskEncryptionSet:
              id: $(< "${SHARED_DIR}"/azure_des_id)
EOF
    fi
    yq-go m -x -i "${CONFIG_PATCH}" "${CONFIG_PATCH_SET}"
fi

if [[ -f "${CONFIG_PATCH}" ]]; then
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
    cat "${CONFIG_PATCH}"
fi