#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [ ! -f "${CONFIG}" ]; then
  echo "No install-config found, exit now"
  exit 1
fi

# Calculate minimum IOPS from throughput for gp3 volumes
# AWS constraint: throughput / iops <= 0.25, so iops >= throughput / 0.25
# Round up to nearest 100 for safety
function get_iops_from_throughput() {
  local throughput="$1"
  local iops=$(( (throughput * 4 + 99) / 100 * 100 ))
  # According to: https://aws.amazon.com/cn/ebs/volume-types
  # The new gp3 volumes deliver a baseline performance of 3,000 IOPS and 125 MiBps at any volume size
  if (( iops < 3000 )); then
    iops=3000
  fi
  echo "${iops}"
}

echo "-------------------------------------------------------------"
echo "Root volume configuration"
echo "-------------------------------------------------------------"

# Handle compute rootVolume configuration
if [[ -n "${AWS_COMPUTE_VOLUME_TYPE:-}" ]]; then
  echo "compute volume type: ${AWS_COMPUTE_VOLUME_TYPE}"
  yq-go w -i "${CONFIG}" "compute[0].platform.aws.rootVolume.type" "${AWS_COMPUTE_VOLUME_TYPE}"
fi
if [[ -n "${AWS_COMPUTE_VOLUME_SIZE:-}" ]]; then
  yq-go w -i "${CONFIG}" "compute[0].platform.aws.rootVolume.size" "${AWS_COMPUTE_VOLUME_SIZE}"
fi
if [[ -n "${AWS_COMPUTE_GP3_THROUGHPUT:-}" ]]; then
  min_iops=$(get_iops_from_throughput "${AWS_COMPUTE_GP3_THROUGHPUT}")
  echo "Calculated minimum IOPS: ${min_iops} (based on throughput ${AWS_COMPUTE_GP3_THROUGHPUT})"
  yq-go w -i "${CONFIG}" "compute[0].platform.aws.rootVolume.iops" "${min_iops}"
  yq-go w -i "${CONFIG}" "compute[0].platform.aws.rootVolume.throughput" "${AWS_COMPUTE_GP3_THROUGHPUT}"
fi

# Handle edge compute pool rootVolume configuration
if [[ "${ENABLE_AWS_EDGE_ZONE:-}" == "yes" ]]; then
  if [[ -n "${AWS_EDGE_VOLUME_TYPE:-}" ]]; then
    echo "edge volume type: ${AWS_EDGE_VOLUME_TYPE}"
    yq-go w -i "${CONFIG}" "compute[1].platform.aws.rootVolume.type" "${AWS_EDGE_VOLUME_TYPE}"
  fi
  if [[ -n "${AWS_EDGE_VOLUME_SIZE:-}" ]]; then
    yq-go w -i "${CONFIG}" "compute[1].platform.aws.rootVolume.size" "${AWS_EDGE_VOLUME_SIZE}"
  fi
  if [[ -n "${AWS_EDGE_GP3_THROUGHPUT:-}" ]]; then
    min_iops=$(get_iops_from_throughput "${AWS_EDGE_GP3_THROUGHPUT}")
    echo "Calculated minimum IOPS: ${min_iops} (based on throughput ${AWS_EDGE_GP3_THROUGHPUT})"
    yq-go w -i "${CONFIG}" "compute[1].platform.aws.rootVolume.iops" "${min_iops}"
    yq-go w -i "${CONFIG}" "compute[1].platform.aws.rootVolume.throughput" "${AWS_EDGE_GP3_THROUGHPUT}"
  fi
fi

# Handle controlPlane rootVolume configuration
if [[ -n "${AWS_CONTROL_PLANE_VOLUME_TYPE:-}" ]]; then
  echo "controlPlane volume type: ${AWS_CONTROL_PLANE_VOLUME_TYPE}"
  yq-go w -i "${CONFIG}" "controlPlane.platform.aws.rootVolume.type" "${AWS_CONTROL_PLANE_VOLUME_TYPE}"
fi
if [[ -n "${AWS_CONTROL_PLANE_VOLUME_SIZE:-}" ]]; then
  yq-go w -i "${CONFIG}" "controlPlane.platform.aws.rootVolume.size" "${AWS_CONTROL_PLANE_VOLUME_SIZE}"
fi
if [[ -n "${AWS_CONTROL_PLANE_GP3_THROUGHPUT:-}" ]]; then
  min_iops=$(get_iops_from_throughput "${AWS_CONTROL_PLANE_GP3_THROUGHPUT}")
  echo "Calculated minimum IOPS: ${min_iops} (based on throughput ${AWS_CONTROL_PLANE_GP3_THROUGHPUT})"
  yq-go w -i "${CONFIG}" "controlPlane.platform.aws.rootVolume.iops" "${min_iops}"
  yq-go w -i "${CONFIG}" "controlPlane.platform.aws.rootVolume.throughput" "${AWS_CONTROL_PLANE_GP3_THROUGHPUT}"
fi

# Handle defaultMachinePlatform rootVolume configuration
# Note: defaultMachinePlatform applies to all pools unless overridden by specific pool settings
if [[ -n "${AWS_DEFAULT_MACHINE_VOLUME_TYPE:-}" ]]; then
  echo "defaultMachinePlatform volume type: ${AWS_DEFAULT_MACHINE_VOLUME_TYPE}"
  yq-go w -i "${CONFIG}" "platform.aws.defaultMachinePlatform.rootVolume.type" "${AWS_DEFAULT_MACHINE_VOLUME_TYPE}"
fi
if [[ -n "${AWS_DEFAULT_MACHINE_VOLUME_SIZE:-}" ]]; then
  yq-go w -i "${CONFIG}" "platform.aws.defaultMachinePlatform.rootVolume.size" "${AWS_DEFAULT_MACHINE_VOLUME_SIZE}"
fi
if [[ -n "${AWS_DEFAULT_GP3_THROUGHPUT:-}" ]]; then
  min_iops=$(get_iops_from_throughput "${AWS_DEFAULT_GP3_THROUGHPUT}")
  echo "Calculated minimum IOPS: ${min_iops} (based on throughput ${AWS_DEFAULT_GP3_THROUGHPUT})"
  yq-go w -i "${CONFIG}" "platform.aws.defaultMachinePlatform.rootVolume.iops" "${min_iops}"
  yq-go w -i "${CONFIG}" "platform.aws.defaultMachinePlatform.rootVolume.throughput" "${AWS_DEFAULT_GP3_THROUGHPUT}"
fi

echo "-------------------------------------------------------------"
echo "Configured root volume settings"
echo "-------------------------------------------------------------"

# Output configured settings for verification
echo "Compute pool rootVolume:"
yq-go r "${CONFIG}" "compute[0]" 2>/dev/null || echo "  (not configured)"

if [[ "${ENABLE_AWS_EDGE_ZONE:-}" == "yes" ]]; then
  echo "Edge pool rootVolume:"
  yq-go r "${CONFIG}" "compute[1]" 2>/dev/null || echo "  (not configured)"
fi

echo "ControlPlane rootVolume:"
yq-go r "${CONFIG}" "controlPlane" 2>/dev/null || echo "  (not configured)"

echo "DefaultMachinePlatform rootVolume:"
yq-go r "${CONFIG}" "platform.aws.defaultMachinePlatform" 2>/dev/null || echo "  (not configured)"
