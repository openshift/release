#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -z "${COMPUTE_DISK_SIZEGB}" ] && [ -z "${CONTROL_PLANE_DISK_SIZEGB}" ] && [ -z "${DEFAULT_MACHINE_PLATFORM_DISK_SIZEGB}" ]; then
  echo "Empty 'COMPUTE_DISK_SIZEGB' / 'CONTROL_PLANE_DISK_SIZEGB' / 'DEFAULT_MACHINE_PLATFORM_DISK_SIZEGB', nothing to do, exiting."
  exit 0
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

echo "COMPUTE_DISK_SIZEGB: ${COMPUTE_DISK_SIZEGB}"
echo "CONTROL_PLANE_DISK_SIZEGB: ${CONTROL_PLANE_DISK_SIZEGB}"
echo "DEFAULT_MACHINE_PLATFORM_DISK_SIZEGB: ${DEFAULT_MACHINE_PLATFORM_DISK_SIZEGB}"

if [ -n "${COMPUTE_DISK_SIZEGB}" ]; then
  cat > "${PATCH}" << EOF
compute:
- name: worker
  platform:
    gcp:
      osDisk: 
        diskSizeGB: ${COMPUTE_DISK_SIZEGB}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated compute[0].platform.gcp.osDisk.diskSizeGB in '${CONFIG}'."
fi

if [ -n "${CONTROL_PLANE_DISK_SIZEGB}" ]; then
  cat > "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    gcp:
      osDisk: 
        diskSizeGB: ${CONTROL_PLANE_DISK_SIZEGB}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated controlPlane.platform.gcp.osDisk.diskSizeGB in '${CONFIG}'."
fi

if [ -n "${DEFAULT_MACHINE_PLATFORM_DISK_SIZEGB}" ]; then
    cat > "${PATCH}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      osDisk: 
        diskSizeGB: ${DEFAULT_MACHINE_PLATFORM_DISK_SIZEGB}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated platform.gcp.defaultMachinePlatform.osDisk.diskSizeGB in '${CONFIG}'."
fi

echo "------------"
yq-go r "${CONFIG}" compute
echo "------------"
yq-go r "${CONFIG}" controlPlane
echo "------------"
yq-go r "${CONFIG}" platform
