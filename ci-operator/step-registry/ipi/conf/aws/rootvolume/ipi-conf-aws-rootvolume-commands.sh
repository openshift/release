#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

function append_throughput_if_needed() {
  local volume_type="$1"
  local patch_file="$2"
  local compute_throughput="${3:-}"
  local control_plane_throughput="${4:-}"

  case "${volume_type}" in
    gp3)
      local throughput=""
      # Priority: compute_throughput > control_plane_throughput > AWS_DEFAULT_GP3_THROUGHPUT
      if [[ -n "${compute_throughput}" ]]; then
        throughput="${compute_throughput}"
      elif [[ -n "${control_plane_throughput}" ]]; then
        throughput="${control_plane_throughput}"
      elif [[ -n "${AWS_DEFAULT_GP3_THROUGHPUT:-}" ]]; then
        throughput="${AWS_DEFAULT_GP3_THROUGHPUT}"
      fi

      if [[ -n "${throughput}" ]]; then
        # Calculate minimum iops required: throughput / iops <= 0.25, so iops >= throughput / 0.25
        # Round up to nearest 100 for safety
        local min_iops=$(( (throughput * 4 + 99) / 100 * 100 ))
        cat >> "${patch_file}" << EOF
        iops: ${min_iops}
        throughput: ${throughput}
EOF
      fi
      ;;
    # Future: add support for other volume types that support throughput
    # gp2)
    #   # gp2 does not support throughput configuration
    #   ;;
  esac
}

# Handle compute rootVolume configuration
if [[ "${AWS_COMPUTE_VOLUME_TYPE}" != "" ]]; then
  echo "Compute volume type: ${AWS_COMPUTE_VOLUME_TYPE}"
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
compute:
- name: worker
  platform:
    aws:
      rootVolume:
        type: ${AWS_COMPUTE_VOLUME_TYPE}
        size: ${AWS_COMPUTE_VOLUME_SIZE}
EOF
  append_throughput_if_needed "${AWS_COMPUTE_VOLUME_TYPE}" "${PATCH}" "${AWS_COMPUTE_GP3_THROUGHPUT:-}" ""
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
elif [[ -n "${AWS_COMPUTE_GP3_THROUGHPUT:-}" ]]; then
  # Only set throughput if volume type is not specified (inherit from defaultMachinePlatform)
  echo "Setting compute rootVolume throughput only: ${AWS_COMPUTE_GP3_THROUGHPUT}"
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
compute:
- name: worker
  platform:
    aws:
      rootVolume:
        throughput: ${AWS_COMPUTE_GP3_THROUGHPUT}
EOF
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

# Handle controlPlane rootVolume configuration
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
  append_throughput_if_needed "${AWS_CONTROL_PLANE_VOLUME_TYPE}" "${PATCH}" "" "${AWS_CONTROL_PLANE_GP3_THROUGHPUT:-}"
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
elif [[ -n "${AWS_CONTROL_PLANE_GP3_THROUGHPUT:-}" ]]; then
  # Only set throughput if volume type is not specified (inherit from defaultMachinePlatform)
  echo "Setting controlPlane rootVolume throughput only: ${AWS_CONTROL_PLANE_GP3_THROUGHPUT}"
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
controlPlane:
  platform:
    aws:
      rootVolume:
        throughput: ${AWS_CONTROL_PLANE_GP3_THROUGHPUT}
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
  append_throughput_if_needed "${AWS_DEFAULT_MACHINE_VOLUME_TYPE}" "${PATCH}"
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi
