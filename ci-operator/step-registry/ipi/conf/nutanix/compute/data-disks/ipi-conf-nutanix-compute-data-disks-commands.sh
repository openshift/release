#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-multi-disks.yaml"

NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
declare data_disk_storage_container
# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

cat >"${PATCH}" <<EOF
compute:
- name: worker
  platform:
    nutanix:
      dataDisks:
      - deviceProperties:
          adapterType: $DATA_DISK_ADAPTER_TYPE
          deviceIndex: 1
          deviceType: Disk
        storageConfig:
          diskMode: Standard
          storageContainer:
            uuid: $data_disk_storage_container
        diskSize: $DATA_DISK_SIZE
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
