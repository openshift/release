#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function swap_machineconfig_generate(){
    local role=$1
    cat >> "${SHARED_DIR}"/openshift_manifests_99-kubelet-config-swap-${role}.yaml << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: 99-swap-config-${role}
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${role}: ""
  kubeletConfig:
    failSwapOn: false
    memorySwap:
      swapBehavior: LimitedSwap
EOF
    cat >> "${SHARED_DIR}"/openshift_manifests_99-kernel-swapaccount-arg-${role}.yaml << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  name: 99-kernel-swapcount-arg-${role}
spec:
  kernelArguments:
    - swapaccount=1
EOF
}

CONFIG="${SHARED_DIR}/install-config.yaml"

# render_pool_disks renders the diskSetup and platform.azure.dataDisks stanzas for one
# machine pool from a disk spec, and prints them indented two spaces so that the caller can
# nest them under either "controlPlane:" or a "compute:" list item.
#
# The spec is one disk per line, with colon-separated fields:
#   type:name:sizeGB:lun:storageAccountType:mountPath
# where type is etcd, swap or user-defined, storageAccountType may be empty to let the
# platform choose, and mountPath is only read for user-defined disks.
#
# Disks are emitted in the order given, because the installer pairs the Nth diskSetup entry
# with the Nth dataDisks entry on Azure.
function render_pool_disks() {
    local spec=$1
    local disk_setup="" data_disks=""
    local dtype dname dsize dlun dsat dmount

    while IFS=':' read -r dtype dname dsize dlun dsat dmount; do
        dtype=$(echo "${dtype}" | tr -d '[:space:]')
        [[ -z "${dtype}" ]] && continue

        dname=$(echo "${dname}" | tr -d '[:space:]')
        dsize=$(echo "${dsize}" | tr -d '[:space:]')
        dlun=$(echo "${dlun}" | tr -d '[:space:]')
        dsat=$(echo "${dsat}" | tr -d '[:space:]')
        dmount=$(echo "${dmount}" | tr -d '[:space:]')

        case "${dtype}" in
            etcd|swap)
                disk_setup+="  - type: ${dtype}
    ${dtype}:
      platformDiskID: \"${dname}\"
"
                ;;
            user-defined)
                if [[ -z "${dmount}" ]]; then
                    echo "ERROR: user-defined disk ${dname} requires a mount path" >&2
                    return 1
                fi
                disk_setup+="  - type: user-defined
    userDefined:
      platformDiskID: \"${dname}\"
      mountPath: ${dmount}
"
                ;;
            *)
                echo "ERROR: unsupported disk type ${dtype}" >&2
                return 1
                ;;
        esac

        data_disks+="      - nameSuffix: \"${dname}\"
        diskSizeGB: ${dsize}
        lun: ${dlun}
"
        if [[ -n "${dsat}" ]]; then
            data_disks+="        managedDisk:
          storageAccountType: ${dsat}
"
        fi
    done <<< "${spec}"

    if [[ -z "${disk_setup}" ]]; then
        return 0
    fi

    printf '  diskSetup:\n%s  platform:\n    azure:\n      dataDisks:\n%s' "${disk_setup}" "${data_disks}"
}

# generate_swap_manifests emits the KubeletConfig and kernel argument manifests that a swap
# disk needs, for every role in the spec that declares one.
function generate_swap_manifests() {
    local spec=$1 role=$2
    local dtype

    while IFS=':' read -r dtype _; do
        dtype=$(echo "${dtype}" | tr -d '[:space:]')
        if [[ "${dtype}" == "swap" ]]; then
            swap_machineconfig_generate "${role}"
            return 0
        fi
    done <<< "${spec}"
}

# When the structured spec is used, it fully describes the disk layout for both pools and
# the single-disk-per-role variables below are ignored. This keeps the older interface
# working for the jobs and chains that still rely on it.
if [[ -n "${AZURE_MULTIDISK_CONTROL_PLANE_DISKS}" ]] || [[ -n "${AZURE_MULTIDISK_COMPUTE_DISKS}" ]]; then
    echo "
Using the structured multi-disk specification.
control plane disks:
${AZURE_MULTIDISK_CONTROL_PLANE_DISKS}
compute disks:
${AZURE_MULTIDISK_COMPUTE_DISKS}
"

    MULTIDISK_PATCH="${SHARED_DIR}/install-config-azure-multidisk.yaml.patch"
    : > "${MULTIDISK_PATCH}"

    if [[ -n "${AZURE_MULTIDISK_CONTROL_PLANE_DISKS}" ]]; then
        cp_body=$(render_pool_disks "${AZURE_MULTIDISK_CONTROL_PLANE_DISKS}")
        echo "controlPlane:" >> "${MULTIDISK_PATCH}"
        echo "${cp_body}" >> "${MULTIDISK_PATCH}"
        generate_swap_manifests "${AZURE_MULTIDISK_CONTROL_PLANE_DISKS}" "master"
    fi

    if [[ -n "${AZURE_MULTIDISK_COMPUTE_DISKS}" ]]; then
        # compute is a list, so the first line of the rendered body becomes the list item.
        compute_body=$(render_pool_disks "${AZURE_MULTIDISK_COMPUTE_DISKS}" | sed '1s/^  /- /')
        echo "compute:" >> "${MULTIDISK_PATCH}"
        echo "${compute_body}" >> "${MULTIDISK_PATCH}"
        generate_swap_manifests "${AZURE_MULTIDISK_COMPUTE_DISKS}" "worker"
    fi

    # Data disks are not supported on the default machine pool, so every disk is attached
    # through the controlPlane and compute pools above.
    yq-go m -x -i "${CONFIG}" "${MULTIDISK_PATCH}"
    echo "install-config patch:"
    cat "${MULTIDISK_PATCH}"
    exit 0
fi

echo "
controlPlane multi disk type: ${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}
    disk size: ${AZURE_CONTROL_PLANE_MULTIDISK_DISK_SIZE}
    disk lun id: ${AZURE_CONTROL_PLANE_MULTIDISK_LUN_ID}
    disk caching type: ${AZURE_CONTROL_PLANE_MULTIDISK_CATCHING_TYPE}
    disk mount path (used for user-defined disk type): ${AZURE_CONTROL_PLANE_MULTIDISK_MOUNT_PATH}
compute multi disk type: ${AZURE_COMPUTE_MULTIDISK_TYPE}
    disk size: ${AZURE_COMPUTE_MULTIDISK_DISK_SIZE}
    disk lun id: ${AZURE_COMPUTE_MULTIDISK_LUN_ID}
    disk caching type: ${AZURE_COMPUTE_MULTIDISK_CATCHING_TYPE}
    disk mount path(used for user-defined disk type): ${AZURE_COMPUTE_MULTIDISK_MOUNT_PATH}
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

# Set caching type for control plane nodes data disk
if [[ -n "${AZURE_CONTROL_PLANE_MULTIDISK_CATCHING_TYPE}" ]]; then
    CONFIG_PATH_CATCHING="$(mktemp)"
    cat > "${CONFIG_PATH_CATCHING}" << EOF
controlPlane:
  platform:
    azure:
      dataDisks:
      - cachingType: "${AZURE_CONTROL_PLANE_MULTIDISK_CATCHING_TYPE}"
EOF
    yq-go m -x -i "${CONFIG_PATCH}" "${CONFIG_PATH_CATCHING}"
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

# Set caching type for compute nodes data disk
if [[ -n "${AZURE_COMPUTE_MULTIDISK_CATCHING_TYPE}" ]]; then
    CONFIG_PATH_CATCHING="$(mktemp)"
    cat > "${CONFIG_PATH_CATCHING}" << EOF
compute:
- platform:
    azure:
      dataDisks:
      - cachingType: "${AZURE_COMPUTE_MULTIDISK_CATCHING_TYPE}"
EOF
    yq-go m -x -i "${CONFIG_PATCH}" "${CONFIG_PATH_CATCHING}"
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

# Generate manifests files when disk type is swap
if [[ "${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}" == "swap" ]]; then
    swap_machineconfig_generate "master"
fi

if [[ "${AZURE_COMPUTE_MULTIDISK_TYPE}" == "swap" ]]; then
    swap_machineconfig_generate "worker"
fi
