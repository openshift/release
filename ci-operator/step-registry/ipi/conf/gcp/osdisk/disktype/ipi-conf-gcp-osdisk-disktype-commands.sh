#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-patch.yaml"

if [[ -n "${COMPUTE_DISK_TYPE}" ]]; then
  cat > "${PATCH}" << EOF
compute:
- name: worker
  platform:
    gcp:
      osDisk: 
        diskType: ${COMPUTE_DISK_TYPE}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated compute[0].platform.gcp.osDisk.diskType in '${CONFIG}'."
  yq-go r "${CONFIG}" compute
fi

if [ -n "${CONTROL_PLANE_DISK_TYPE}" ]; then
  cat > "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    gcp:
      osDisk: 
        diskType: ${CONTROL_PLANE_DISK_TYPE}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated controlPlane.platform.gcp.osDisk.diskType in '${CONFIG}'."
  yq-go r "${CONFIG}" controlPlane
fi

if [ -n "${DEFAULT_MACHINE_PLATFORM_DISK_TYPE}" ]; then
  cat > "${PATCH}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      osDisk: 
        diskType: ${DEFAULT_MACHINE_PLATFORM_DISK_TYPE}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated platform.gcp.defaultMachinePlatform.osDisk.diskType in '${CONFIG}'."
  yq-go r "${CONFIG}" platform
fi