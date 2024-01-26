#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -z "${COMPUTE_DISK_SIZEGB}" ] && [ -z "${CONTROL_PLANE_DISK_SIZEGB}" ]; then
  echo "Empty 'COMPUTE_DISK_SIZEGB' and 'CONTROL_PLANE_DISK_SIZEGB', nothing to do, exiting."
  exit 0
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

echo "COMPUTE_DISK_SIZEGB: ${COMPUTE_DISK_SIZEGB}"
echo "CONTROL_PLANE_DISK_SIZEGB: ${CONTROL_PLANE_DISK_SIZEGB}"

if [ -n "${COMPUTE_DISK_SIZEGB}" ]; then
  cat > "${PATCH}" << EOF
compute:
- name: worker
  platform:
    gcp:
      osDisk: 
        diskSizeGB: ${COMPUTE_DISK_SIZEGB}
EOF
fi

if [ -n "${CONTROL_PLANE_DISK_SIZEGB}" ]; then
  cat >> "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    gcp:
      osDisk: 
        diskSizeGB: ${CONTROL_PLANE_DISK_SIZEGB}
EOF
fi

yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated osDisk.diskSizeGB in '${CONFIG}'."
echo "------------"
yq-go r "${CONFIG}" platform
echo "------------"
yq-go r "${CONFIG}" compute
echo "------------"
yq-go r "${CONFIG}" controlPlane
