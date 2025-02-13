#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/service-account.yaml.patch"

if [ -n "${COMPUTE_SERVICE_ACCOUNT}" ]; then
  cat > "${PATCH}" << EOF
compute:
- platform:
    gcp:
      serviceAccount: ${COMPUTE_SERVICE_ACCOUNT}
EOF
fi

if [ -n "${CONTROL_PLANE_SERVICE_ACCOUNT}" ]; then
  cat >> "${PATCH}" << EOF
controlPlane:
  platform:
    gcp:
      serviceAccount: ${CONTROL_PLANE_SERVICE_ACCOUNT}
EOF
fi

if [ -n "${DEFAULT_MACHINE_SERVICE_ACCOUNT}" ]; then
  cat >> "${PATCH}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      serviceAccount: ${DEFAULT_MACHINE_SERVICE_ACCOUNT}
EOF
fi

if [ -s "${PATCH}" ]; then
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  yq-go r "${CONFIG}" compute
  yq-go r "${CONFIG}" controlPlane
  yq-go r "${CONFIG}" platform

  rm "${PATCH}"
fi