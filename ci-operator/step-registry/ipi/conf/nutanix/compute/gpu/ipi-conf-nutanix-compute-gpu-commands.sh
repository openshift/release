#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-gpu.yaml"

NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
declare gpu_name
declare gpu_device_id
# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

cat >"${PATCH}" <<EOF
compute:
- name: worker
  platform:
    nutanix:
      gpus:
        - type: Name
          name: "$gpu_name"
        - type: DeviceID
          deviceID: $gpu_device_id
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
