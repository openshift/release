#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

function append_throughput_if_needed() {
  local volume_type="$1"
  local patch_file="$2"

  if [[ "${volume_type}" == "gp3" && -n "${AWS_GP3_THROUGHPUT:-}" ]]; then
    cat >> "${patch_file}" << EOF
        throughput: ${AWS_GP3_THROUGHPUT}
EOF
  fi
}

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
  append_throughput_if_needed "${AWS_COMPUTE_VOLUME_TYPE}" "${PATCH}"
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
  append_throughput_if_needed "${AWS_CONTROL_PLANE_VOLUME_TYPE}" "${PATCH}"
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
  append_throughput_if_needed "${AWS_DEFAULT_MACHINE_VOLUME_TYPE}" "${PATCH}"
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi
