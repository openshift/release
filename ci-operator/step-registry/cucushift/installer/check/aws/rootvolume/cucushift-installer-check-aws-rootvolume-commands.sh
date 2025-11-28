#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

# Get cluster infrastructure details
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || true)
if [ -z "${INFRA_ID}" ] && [ -f "${SHARED_DIR}/metadata.json" ]; then
  INFRA_ID=$(grep -o '"infraID":"[^"]*"' "${SHARED_DIR}/metadata.json" 2>/dev/null | head -n1 | cut -d':' -f2 | tr -d '"')
fi
CLUSTER_ID="${INFRA_ID}"
REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')

# Handle C2S/SC2S regions
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=""
  if [ -f "${CLUSTER_PROFILE_DIR}/shift_project_setting.json" ] && command -v python3 >/dev/null 2>&1; then
    source_region=$(python3 - "$REGION" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json" <<'PY'
import json, sys
region = sys.argv[1]
path = sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    value = data.get(region, {}).get("source_region")
    if value:
        print(value)
except Exception:
    pass
PY
)
  fi
  if [ -n "${source_region}" ] && [ "${source_region}" != "null" ]; then
    REGION=$source_region
  fi
fi

echo "Cluster ID: ${CLUSTER_ID}"
echo "Region: ${REGION}"

function read_install_config() {
  local query="$1"
  if [ ! -f "${SHARED_DIR}/install-config.yaml" ]; then
    return
  fi
  yq-go r "${SHARED_DIR}/install-config.yaml" "${query}" 2>/dev/null || true
}

# Read throughput values from install-config.yaml
# Priority: split config > defaultMachinePlatform
COMPUTE_THROUGHPUT=$(read_install_config 'compute[0].platform.aws.rootVolume.throughput')
CONTROL_PLANE_THROUGHPUT=$(read_install_config 'controlPlane.platform.aws.rootVolume.throughput')
DEFAULT_THROUGHPUT=$(read_install_config 'platform.aws.defaultMachinePlatform.rootVolume.throughput')

# Determine expected throughput: split config overrides defaultMachinePlatform
EXPECTED_COMPUTE_THROUGHPUT="${COMPUTE_THROUGHPUT}"
[ -z "${EXPECTED_COMPUTE_THROUGHPUT}" ] || [ "${EXPECTED_COMPUTE_THROUGHPUT}" == "null" ] && \
  EXPECTED_COMPUTE_THROUGHPUT="${DEFAULT_THROUGHPUT}"

EXPECTED_CONTROL_PLANE_THROUGHPUT="${CONTROL_PLANE_THROUGHPUT}"
[ -z "${EXPECTED_CONTROL_PLANE_THROUGHPUT}" ] || [ "${EXPECTED_CONTROL_PLANE_THROUGHPUT}" == "null" ] && \
  EXPECTED_CONTROL_PLANE_THROUGHPUT="${DEFAULT_THROUGHPUT}"

# Read size values from install-config.yaml
# Priority: split config > defaultMachinePlatform
COMPUTE_SIZE=$(read_install_config 'compute[0].platform.aws.rootVolume.size')
CONTROL_PLANE_SIZE=$(read_install_config 'controlPlane.platform.aws.rootVolume.size')
DEFAULT_SIZE=$(read_install_config 'platform.aws.defaultMachinePlatform.rootVolume.size')

# Determine expected size: split config overrides defaultMachinePlatform
EXPECTED_COMPUTE_SIZE="${COMPUTE_SIZE}"
[ -z "${EXPECTED_COMPUTE_SIZE}" ] || [ "${EXPECTED_COMPUTE_SIZE}" == "null" ] && \
  EXPECTED_COMPUTE_SIZE="${DEFAULT_SIZE}"

EXPECTED_CONTROL_PLANE_SIZE="${CONTROL_PLANE_SIZE}"
[ -z "${EXPECTED_CONTROL_PLANE_SIZE}" ] || [ "${EXPECTED_CONTROL_PLANE_SIZE}" == "null" ] && \
  EXPECTED_CONTROL_PLANE_SIZE="${DEFAULT_SIZE}"

# Verify that size values can be read from install-config
if [ -z "${EXPECTED_COMPUTE_SIZE}" ] || [ "${EXPECTED_COMPUTE_SIZE}" == "null" ]; then
  echo "ERROR: Unable to read compute rootVolume size from install-config.yaml"
  exit 1
fi
if [ -z "${EXPECTED_CONTROL_PLANE_SIZE}" ] || [ "${EXPECTED_CONTROL_PLANE_SIZE}" == "null" ]; then
  echo "ERROR: Unable to read control plane rootVolume size from install-config.yaml"
  exit 1
fi

echo "Expected compute throughput: ${EXPECTED_COMPUTE_THROUGHPUT:-N/A} MiB/s"
echo "Expected control plane throughput: ${EXPECTED_CONTROL_PLANE_THROUGHPUT:-N/A} MiB/s"
echo "Expected worker rootVolume size: ${EXPECTED_COMPUTE_SIZE} GiB"
echo "Expected control-plane rootVolume size: ${EXPECTED_CONTROL_PLANE_SIZE} GiB"

ret=0
declare -a FAILURE_SUMMARY=()

function log_machine_root_volume_spec() {
  local node_name="$1"
  local machine_ref="$2"

  if [ -z "${machine_ref}" ]; then
    return
  fi

  local machine_ns="${machine_ref%%/*}"
  local machine_name="${machine_ref##*/}"
  local spec_output spec_type spec_size spec_throughput

  spec_output=$(oc get machine -n "${machine_ns}" "${machine_name}" -o jsonpath='{.spec.providerSpec.value.rootVolume.type} {.spec.providerSpec.value.rootVolume.size} {.spec.providerSpec.value.rootVolume.throughput}' 2>/dev/null || true)
  if [ -z "${spec_output}" ]; then
    return
  fi

  read -r spec_type spec_size spec_throughput <<< "${spec_output}"
  spec_type=${spec_type:-N/A}
  spec_size=${spec_size:-N/A}
  spec_throughput=${spec_throughput:-N/A}

  if [ "${spec_type}" == "N/A" ] && [ "${spec_size}" == "N/A" ] && [ "${spec_throughput}" == "N/A" ]; then
    return
  fi

  echo "INFO: ${node_name} desired rootVolume spec (machine ${machine_ref}) type=${spec_type} size=${spec_size}GiB throughput=${spec_throughput}MiB/s"
}

function verify_nodes() {
  local role_label="$1"
  local role_name="$2"
  local expected_size="$3"
  local expected_throughput="$4"

  local nodes
  nodes=$(oc get nodes -l "${role_label}" -o jsonpath='{.items[*].metadata.name}')
  if [ -z "${nodes}" ]; then
    echo "WARNING: No ${role_name} nodes found, skipping"
    return
  fi

  for node in ${nodes}; do
    local instance_id volume_id volume_type volume_throughput
    local volume_size volume_iops
    local machine_ref

    instance_id=$(oc get node "${node}" -o jsonpath='{.spec.providerID}' | sed 's|.*/||')
    machine_ref=$(oc get node "${node}" -o jsonpath='{.metadata.annotations.machine\.openshift\.io/machine}')
    if [ -z "${instance_id}" ]; then
      echo "WARNING: ${role_name} ${node} has no providerID, skipping"
      log_machine_root_volume_spec "${node}" "${machine_ref}"
      continue
    fi

    volume_id=$(aws ec2 describe-instances --instance-ids "${instance_id}" --region "${REGION}" \
      --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==\`/dev/sda1\`].Ebs.VolumeId" --output text)
    if [ -z "${volume_id}" ] || [ "${volume_id}" == "None" ]; then
      volume_id=$(aws ec2 describe-instances --instance-ids "${instance_id}" --region "${REGION}" \
        --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==\`/dev/xvda\`].Ebs.VolumeId" --output text)
    fi
    if [ -z "${volume_id}" ] || [ "${volume_id}" == "None" ]; then
      echo "WARNING: ${role_name} ${node} has no root volume ID, skipping"
      log_machine_root_volume_spec "${node}" "${machine_ref}"
      continue
    fi

    read -r volume_type volume_size volume_iops volume_throughput < <(aws ec2 describe-volumes --volume-ids "${volume_id}" --region "${REGION}" --query 'Volumes[0].[VolumeType,Size,Iops,Throughput]' --output text 2>/dev/null || echo "N/A N/A N/A N/A")
    if [ "${volume_type}" == "None" ] && [ "${volume_size}" == "None" ] && [ "${volume_throughput}" == "None" ]; then
      volume_type="N/A"
      volume_size="N/A"
      volume_iops="N/A"
      volume_throughput="N/A"
    fi
    if [ "${volume_type}" == "N/A" ] && [ "${volume_size}" == "N/A" ] && [ "${volume_throughput}" == "N/A" ]; then
      echo "ERROR: Unable to describe volume ${volume_id}"
      FAILURE_SUMMARY+=("${node}: unable to describe volume")
      ret=$((ret+1))
      log_machine_root_volume_spec "${node}" "${machine_ref}"
      continue
    fi

    if [ "${volume_throughput}" == "N/A" ] || [ "${volume_throughput}" == "null" ]; then
      echo "ERROR: ${node} ${volume_type} volume ${volume_id} missing throughput metadata (size=${volume_size}GiB iops=${volume_iops})"
      FAILURE_SUMMARY+=("${node}: throughput missing")
      ret=$((ret+1))
      continue
    fi

    if [ -n "${expected_throughput}" ] && [ "${volume_throughput}" -ne "${expected_throughput}" ]; then
      echo "ERROR: ${node} volume ${volume_id} throughput ${volume_throughput} differs from expected ${expected_throughput} (type=${volume_type} size=${volume_size}GiB iops=${volume_iops})"
      FAILURE_SUMMARY+=("${node}: throughput ${volume_throughput}")
      ret=$((ret+1))
      continue
    fi

    if [ -n "${expected_size}" ] && [ "${volume_size}" -ne "${expected_size}" ]; then
      echo "ERROR: ${node} volume ${volume_id} size ${volume_size} differs from expected ${expected_size}GiB (type=${volume_type} throughput=${volume_throughput}MiB/s)"
      FAILURE_SUMMARY+=("${node}: size ${volume_size}")
      ret=$((ret+1))
      continue
    fi

    echo "PASS: ${node} volume ${volume_id} type=${volume_type} size=${volume_size}GiB iops=${volume_iops} throughput=${volume_throughput}MiB/s"
  done
}

echo "Checking worker nodes"
verify_nodes "node-role.kubernetes.io/worker" "worker" "${EXPECTED_COMPUTE_SIZE}" "${EXPECTED_COMPUTE_THROUGHPUT}"

echo "Checking control plane nodes"
verify_nodes "node-role.kubernetes.io/master" "control plane" "${EXPECTED_CONTROL_PLANE_SIZE}" "${EXPECTED_CONTROL_PLANE_THROUGHPUT}"

echo "=========================================="
echo "Test Summary"
if [ ${ret} -eq 0 ]; then
  echo "All root volume throughput checks passed."
else
  printf 'Failures:\n'
  printf ' - %s\n' "${FAILURE_SUMMARY[@]}"
fi

exit ${ret}
