#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

# Calculate minimum IOPS from throughput for gp3 volumes
# AWS constraint: throughput / iops <= 0.25, so iops >= throughput / 0.25
# Round up to nearest 100 for safety
function get_iops_from_throughput() {
  local throughput="$1"
  echo $(( (throughput * 4 + 99) / 100 * 100 ))
}

# Configure rootVolume for a compute pool, controlPlane, or defaultMachinePlatform
# Args:
#   $1: pool_path - YAML path to the pool (e.g., "compute[0]", "controlPlane", "platform.aws.defaultMachinePlatform")
#   $2: volume_type - Volume type (e.g., "gp3", "gp2") or empty string
#   $3: volume_size - Volume size (e.g., "120") or empty string
#   $4: throughput - Throughput for gp3 volumes (e.g., "1000") or empty string
#   $5: pool_name - Human-readable name for logging (e.g., "compute", "edge", "controlPlane", "defaultMachinePlatform")
function configure_root_volume() {
  local pool_path="$1"
  local volume_type="$2"
  local volume_size="$3"
  local throughput="$4"
  local pool_name="$5"
  
  # Determine the correct rootVolume path based on pool type
  # For defaultMachinePlatform, path is: platform.aws.defaultMachinePlatform.rootVolume.*
  # For other pools (compute, controlPlane), path is: pool_path.platform.aws.rootVolume.*
  local root_volume_path
  if [[ "${pool_path}" == "platform.aws.defaultMachinePlatform" ]]; then
    root_volume_path="${pool_path}.rootVolume"
  else
    root_volume_path="${pool_path}.platform.aws.rootVolume"
  fi
  
  # Set type if provided
  if [[ -n "${volume_type}" ]]; then
    echo "${pool_name} volume type: ${volume_type}"
    yq-go w -i "${CONFIG}" "${root_volume_path}.type" "${volume_type}"
  fi
  
  # Set size if provided
  if [[ -n "${volume_size}" ]]; then
    yq-go w -i "${CONFIG}" "${root_volume_path}.size" "${volume_size}"
  fi
  
  # Set throughput and calculate iops if provided
  if [[ -n "${throughput}" ]]; then
    local min_iops
    min_iops=$(get_iops_from_throughput "${throughput}")
    echo "Calculated minimum IOPS: ${min_iops} (based on throughput ${throughput})"
    yq-go w -i "${CONFIG}" "${root_volume_path}.iops" "${min_iops}"
    yq-go w -i "${CONFIG}" "${root_volume_path}.throughput" "${throughput}"
  fi
}

# Check if edge compute pool exists at index 1
# Returns the pool path if exists, empty string otherwise
function get_edge_pool_path() {
  local pool_name
  pool_name=$(yq-go r "${CONFIG}" "compute[1].name" 2>/dev/null || echo "")
  if [[ "${pool_name}" == "edge" ]]; then
    echo "compute[1]"
  else
    echo ""
  fi
}

echo "-------------------------------------------------------------"
echo "Root volume configuration"
echo "-------------------------------------------------------------"

# Handle compute rootVolume configuration
if [[ -n "${AWS_COMPUTE_VOLUME_TYPE:-}" ]] || [[ -n "${AWS_COMPUTE_GP3_THROUGHPUT:-}" ]]; then
  configure_root_volume \
    "compute[0]" \
    "${AWS_COMPUTE_VOLUME_TYPE:-}" \
    "${AWS_COMPUTE_VOLUME_SIZE:-}" \
    "${AWS_COMPUTE_GP3_THROUGHPUT:-}" \
    "compute"
fi

# Handle edge compute pool rootVolume configuration
if [[ "${ENABLE_AWS_EDGE_ZONE:-}" == "yes" ]]; then
  if [[ -n "${AWS_EDGE_VOLUME_TYPE:-}" ]] || [[ -n "${AWS_EDGE_GP3_THROUGHPUT:-}" ]]; then
    edge_pool_path=$(get_edge_pool_path)
    configure_root_volume \
      "${edge_pool_path}" \
      "${AWS_EDGE_VOLUME_TYPE:-}" \
      "${AWS_EDGE_VOLUME_SIZE:-}" \
      "${AWS_EDGE_GP3_THROUGHPUT:-}" \
      "edge"
    
    # Output updated edge compute pool configuration
    echo "Updated edge compute pool rootVolume configuration:"
    yq-go r "${CONFIG}" "${edge_pool_path}.platform.aws.rootVolume" || true
  fi
fi

# Handle controlPlane rootVolume configuration
if [[ -n "${AWS_CONTROL_PLANE_VOLUME_TYPE:-}" ]] || [[ -n "${AWS_CONTROL_PLANE_GP3_THROUGHPUT:-}" ]]; then
  configure_root_volume \
    "controlPlane" \
    "${AWS_CONTROL_PLANE_VOLUME_TYPE:-}" \
    "${AWS_CONTROL_PLANE_VOLUME_SIZE:-}" \
    "${AWS_CONTROL_PLANE_GP3_THROUGHPUT:-}" \
    "controlPlane"
fi

# Handle defaultMachinePlatform rootVolume configuration
# Note: defaultMachinePlatform applies to all pools unless overridden by specific pool settings
if [[ "${AWS_DEFAULT_GP3_THROUGHPUT:-}" != "" ]]; then
  PATCH=$(mktemp)
  cat >> "${PATCH}" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        throughput: ${AWS_DEFAULT_GP3_THROUGHPUT}
        iops: $(get_iops_from_throughput "${AWS_DEFAULT_GP3_THROUGHPUT}")
EOF
  cat "${PATCH}"
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${AWS_DEFAULT_MACHINE_VOLUME_TYPE:-}" != "" ]]; then
  configure_root_volume \
    "platform.aws.defaultMachinePlatform" \
    "${AWS_DEFAULT_MACHINE_VOLUME_TYPE:-}" \
    "${AWS_DEFAULT_MACHINE_VOLUME_SIZE:-}" \
    "" \
    "defaultMachinePlatform"
fi

echo "-------------------------------------------------------------"
echo "Configured root volume settings"
echo "-------------------------------------------------------------"

# Output configured settings for verification
if [[ -n "${AWS_COMPUTE_VOLUME_TYPE:-}" ]] || [[ -n "${AWS_COMPUTE_GP3_THROUGHPUT:-}" ]]; then
  echo "Compute pool rootVolume:"
  yq-go r "${CONFIG}" "compute[0].platform.aws.rootVolume" 2>/dev/null || echo "  (not configured)"
fi

if [[ -n "${AWS_EDGE_VOLUME_TYPE:-}" ]] || [[ -n "${AWS_EDGE_GP3_THROUGHPUT:-}" ]]; then
  edge_pool_path=$(get_edge_pool_path)
  echo "Edge pool rootVolume:"
  yq-go r "${CONFIG}" "${edge_pool_path}.platform.aws.rootVolume" 2>/dev/null || echo "  (not configured)"
fi

if [[ -n "${AWS_CONTROL_PLANE_VOLUME_TYPE:-}" ]] || [[ -n "${AWS_CONTROL_PLANE_GP3_THROUGHPUT:-}" ]]; then
  echo "ControlPlane rootVolume:"
  yq-go r "${CONFIG}" "controlPlane.platform.aws.rootVolume" 2>/dev/null || echo "  (not configured)"
fi

if [[ -n "${AWS_DEFAULT_MACHINE_VOLUME_TYPE:-}" ]]; then
  echo "DefaultMachinePlatform rootVolume:"
  yq-go r "${CONFIG}" "platform.aws.defaultMachinePlatform.rootVolume" 2>/dev/null || echo "  (not configured)"
fi
