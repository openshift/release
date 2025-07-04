#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/confidential_computing.yaml.patch"

if [[ -n "${COMPUTE_CONFIDENTIAL_COMPUTE}" ]] && [[ -n "${COMPUTE_ON_HOST_MAINTENANCE}" ]]; then
  cat > "${PATCH}" << EOF
compute:
- name: worker
  platform:
    gcp:
      confidentialCompute: ${COMPUTE_CONFIDENTIAL_COMPUTE}
      onHostMaintenance: ${COMPUTE_ON_HOST_MAINTENANCE}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  yq-go r "${CONFIG}" compute
fi

if [[ -n "${CONTROL_PLANE_CONFIDENTIAL_COMPUTE}" ]] && [[ -n "${CONTROL_PLANE_ON_HOST_MAINTENANCE}" ]]; then
  cat > "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    gcp:
      confidentialCompute: ${CONTROL_PLANE_CONFIDENTIAL_COMPUTE}
      onHostMaintenance: ${CONTROL_PLANE_ON_HOST_MAINTENANCE}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  yq-go r "${CONFIG}" controlPlane
fi

if [[ -n "${CONFIDENTIAL_COMPUTE}" ]] && [[ -n "${ON_HOST_MAINTENANCE}" ]]; then
  cat > "${PATCH}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      confidentialCompute: ${CONFIDENTIAL_COMPUTE}
      onHostMaintenance: ${ON_HOST_MAINTENANCE}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  yq-go r "${CONFIG}" platform
fi


rm "${PATCH}"
