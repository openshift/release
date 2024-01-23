#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ "${AWS_COMPUTE_VOLUME_TYPE}" != "" ]]; then
  echo "Compute volume type: ${AWS_COMPUTE_VOLUME_TYPE}"
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
compute:
- platform:
    aws:
      rootVolume:
        type: ${AWS_COMPUTE_VOLUME_TYPE}
        size: ${AWS_COMPUTE_VOLUME_SIZE}
EOF
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${AWS_CONTROL_PLANE_VOLUME_TYPE}" != "" ]]; then
  echo "Control plane volume type: ${AWS_CONTROL_PLANE_VOLUME_TYPE}"
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
controlPlane:
  platform:
    aws:
      rootVolume:
        type: ${AWS_CONTROL_PLANE_VOLUME_TYPE}
        size: ${AWS_CONTROL_PLANE_VOLUME_SIZE}
EOF
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${AWS_DEFAULT_MACHINE_VOLUME_TYPE}" != "" ]]; then
  echo "Default machine volume type: ${AWS_DEFAULT_MACHINE_VOLUME_TYPE}"
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        type: ${AWS_DEFAULT_MACHINE_VOLUME_TYPE}
        size: ${AWS_DEFAULT_MACHINE_VOLUME_SIZE}
EOF
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi
