#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "controlPlane multi disk type: ${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}"

# Set disk type for control plane nodes
CONFIG_PATCH="${SHARED_DIR}/install-config-azure-disk-type.yaml.patch"
if [[ "${AZURE_CONTROL_PLANE_MULTIDISK_TYPE}" == "etcd" ]]; then
    cat >> "${CONFIG_PATCH}" << EOF
controlPlane:
  diskSetup:
  - type: etcd
    etcd:
      platformDiskID: "etcddisk"
  platform:
    azure:
      dataDisks:
      - nameSuffix: etcddisk
        diskSizeGB: 64
        lun: 0
EOF
fi

if [[ -f "${CONFIG_PATCH}" ]]; then
    yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
    cat "${CONFIG_PATCH}"
fi
