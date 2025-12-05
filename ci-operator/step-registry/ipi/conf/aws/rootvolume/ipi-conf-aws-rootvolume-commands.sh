#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

# Append throughput and iops configuration for gp3 volume type.
# This function only configures what is passed in - no priority checks or fallbacks.
# Caller is responsible for providing correct parameters.
function append_throughput_for_gp3() {
  local volume_type="$1"
  local patch_file="$2"
  local throughput="${3:-}"

  if [[ "${volume_type}" == "gp3" ]] && [[ -n "${throughput}" ]]; then
    # Calculate minimum iops required: throughput / iops <= 0.25, so iops >= throughput / 0.25
    # Round up to nearest 100 for safety
    local min_iops=$(( (throughput * 4 + 99) / 100 * 100 ))
    cat >> "${patch_file}" << EOF
        iops: ${min_iops}
        throughput: ${throughput}
EOF
  fi
}

# Handle compute rootVolume configuration
# Users can set AWS_COMPUTE_VOLUME_TYPE and AWS_COMPUTE_GP3_THROUGHPUT together
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
  # Append throughput if provided (only for gp3)
  append_throughput_for_gp3 "${AWS_COMPUTE_VOLUME_TYPE}" "${PATCH}" "${AWS_COMPUTE_GP3_THROUGHPUT:-}"
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

# If only throughput is specified (without volume type), set throughput only
# This allows inheriting volume type from defaultMachinePlatform
if [[ "${AWS_COMPUTE_VOLUME_TYPE}" == "" ]] && [[ -n "${AWS_COMPUTE_GP3_THROUGHPUT:-}" ]]; then
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

# Handle edge compute pool rootVolume configuration
# Users can set AWS_EDGE_VOLUME_TYPE and AWS_EDGE_GP3_THROUGHPUT together
if [[ "${AWS_EDGE_VOLUME_TYPE}" != "" ]]; then
  echo "Edge volume type: ${AWS_EDGE_VOLUME_TYPE}"
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
compute:
- name: edge
  platform:
    aws:
      rootVolume:
        type: ${AWS_EDGE_VOLUME_TYPE}
        size: ${AWS_EDGE_VOLUME_SIZE}
EOF
  append_throughput_for_gp3 "${AWS_EDGE_VOLUME_TYPE}" "${PATCH}" "${AWS_EDGE_GP3_THROUGHPUT:-}"
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

# If only throughput is specified for edge (without volume type), set throughput only
if [[ "${AWS_EDGE_VOLUME_TYPE}" == "" ]] && [[ -n "${AWS_EDGE_GP3_THROUGHPUT:-}" ]]; then
  echo "Setting edge rootVolume throughput only: ${AWS_EDGE_GP3_THROUGHPUT}"
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
compute:
- name: edge
  platform:
    aws:
      rootVolume:
        throughput: ${AWS_EDGE_GP3_THROUGHPUT}
EOF
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

# Handle controlPlane rootVolume configuration
# Users can set AWS_CONTROL_PLANE_VOLUME_TYPE and AWS_CONTROL_PLANE_GP3_THROUGHPUT together
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
  # Append throughput if provided (only for gp3)
  append_throughput_for_gp3 "${AWS_CONTROL_PLANE_VOLUME_TYPE}" "${PATCH}" "${AWS_CONTROL_PLANE_GP3_THROUGHPUT:-}"
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

# If only throughput is specified (without volume type), set throughput only
# This allows inheriting volume type from defaultMachinePlatform
if [[ "${AWS_CONTROL_PLANE_VOLUME_TYPE}" == "" ]] && [[ -n "${AWS_CONTROL_PLANE_GP3_THROUGHPUT:-}" ]]; then
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

# Handle defaultMachinePlatform rootVolume configuration
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
  # Append throughput if provided (only for gp3)
  append_throughput_for_gp3 "${AWS_DEFAULT_MACHINE_VOLUME_TYPE}" "${PATCH}" "${AWS_DEFAULT_GP3_THROUGHPUT:-}"
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi
