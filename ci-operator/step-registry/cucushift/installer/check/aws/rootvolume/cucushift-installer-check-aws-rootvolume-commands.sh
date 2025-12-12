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
INFRA_ID=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
CLUSTER_ID="${INFRA_ID}"
REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')

echo "Cluster ID: ${CLUSTER_ID}"
echo "Region: ${REGION}"

CONFIG="${SHARED_DIR}/install-config.yaml"

function read_install_config() {
  local query="$1"
  if [ ! -f "${CONFIG}" ]; then
    return
  fi
  yq-go r "${CONFIG}" "${query}" 2>/dev/null || true
}

# Read throughput values from install-config.yaml
# Priority: split config > defaultMachinePlatform
CONTROL_PLANE_THROUGHPUT=$(read_install_config 'controlPlane.platform.aws.rootVolume.throughput')
DEFAULT_THROUGHPUT=$(read_install_config 'platform.aws.defaultMachinePlatform.rootVolume.throughput')

# Read compute pool configurations
# In Phase 2 workflow, worker pool is at compute[0], edge pool is at compute[1]
COMPUTE_THROUGHPUT=$(read_install_config "compute[0].platform.aws.rootVolume.throughput")
COMPUTE_SIZE=$(read_install_config "compute[0].platform.aws.rootVolume.size")

# Read edge pool configuration
EDGE_THROUGHPUT=$(read_install_config "compute[1].platform.aws.rootVolume.throughput")
EDGE_SIZE=$(read_install_config "compute[1].platform.aws.rootVolume.size")

# Determine expected throughput: split config overrides defaultMachinePlatform
# Priority: pool-specific config > defaultMachinePlatform
EXPECTED_COMPUTE_THROUGHPUT="${COMPUTE_THROUGHPUT:-${DEFAULT_THROUGHPUT}}"
EXPECTED_CONTROL_PLANE_THROUGHPUT="${CONTROL_PLANE_THROUGHPUT:-${DEFAULT_THROUGHPUT}}"

# Determine expected edge throughput
EXPECTED_EDGE_THROUGHPUT=""
if [[ -n "${EDGE_THROUGHPUT}" ]]; then
  EXPECTED_EDGE_THROUGHPUT="${EDGE_THROUGHPUT}"
elif [[ -n "${EDGE_SIZE}" ]]; then
  # Edge pool exists but throughput not explicitly set, use default
  EXPECTED_EDGE_THROUGHPUT="${DEFAULT_THROUGHPUT}"
fi

# Read size values from install-config.yaml
CONTROL_PLANE_SIZE=$(read_install_config 'controlPlane.platform.aws.rootVolume.size')
DEFAULT_SIZE=$(read_install_config 'platform.aws.defaultMachinePlatform.rootVolume.size')

# Determine expected size: split config overrides defaultMachinePlatform
# Priority: pool-specific config > defaultMachinePlatform
EXPECTED_COMPUTE_SIZE="${COMPUTE_SIZE:-${DEFAULT_SIZE}}"
EXPECTED_CONTROL_PLANE_SIZE="${CONTROL_PLANE_SIZE:-${DEFAULT_SIZE}}"

# Determine expected edge size
EXPECTED_EDGE_SIZE=""
if [[ -n "${EDGE_SIZE}" ]]; then
  EXPECTED_EDGE_SIZE="${EDGE_SIZE}"
elif [[ -n "${EDGE_THROUGHPUT}" ]]; then
  # Edge pool exists but size not explicitly set, use default
  EXPECTED_EDGE_SIZE="${DEFAULT_SIZE}"
fi


echo "-------------------------------------------------------------"
echo "Expected root volume configuration"
echo "-------------------------------------------------------------"
echo "Configuration priority: pool-specific settings > defaultMachinePlatform"
echo ""
echo "Worker rootVolume:"
echo "  size: ${EXPECTED_COMPUTE_SIZE} GiB"
echo "  throughput: ${EXPECTED_COMPUTE_THROUGHPUT} MiB/s"
if [[ -n "${COMPUTE_THROUGHPUT}" ]]; then
  echo "  (from compute[0].platform.aws.rootVolume)"
elif [[ -n "${DEFAULT_THROUGHPUT}" ]]; then
  echo "  (from platform.aws.defaultMachinePlatform.rootVolume)"
fi
echo "Control-plane rootVolume:"
echo "  size: ${EXPECTED_CONTROL_PLANE_SIZE} GiB"
echo "  throughput: ${EXPECTED_CONTROL_PLANE_THROUGHPUT} MiB/s"
if [[ -n "${CONTROL_PLANE_THROUGHPUT}" ]]; then
  echo "  (from controlPlane.platform.aws.rootVolume)"
elif [[ -n "${DEFAULT_THROUGHPUT}" ]]; then
  echo "  (from platform.aws.defaultMachinePlatform.rootVolume)"
fi
echo "Edge rootVolume:"
echo "  size: ${EXPECTED_EDGE_SIZE} GiB"
echo "  throughput: ${EXPECTED_EDGE_THROUGHPUT} MiB/s"
if [[ -n "${EDGE_THROUGHPUT}" ]]; then
  echo "  (from compute[1].platform.aws.rootVolume)"
elif [[ -n "${DEFAULT_THROUGHPUT}" ]]; then
  echo "  (from platform.aws.defaultMachinePlatform.rootVolume)"
fi

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
  local spec_type spec_size spec_throughput

  spec_type=$(oc get machine -n "${machine_ns}" "${machine_name}" -o jsonpath='{.spec.providerSpec.value.rootVolume.type}' 2>/dev/null || true)
  spec_size=$(oc get machine -n "${machine_ns}" "${machine_name}" -o jsonpath='{.spec.providerSpec.value.rootVolume.size}' 2>/dev/null || true)
  spec_throughput=$(oc get machine -n "${machine_ns}" "${machine_name}" -o jsonpath='{.spec.providerSpec.value.rootVolume.throughput}' 2>/dev/null || true)

  if [[ -n "${spec_type}" ]] || [[ -n "${spec_size}" ]] || [[ -n "${spec_throughput}" ]]; then
    echo "INFO: ${node_name} desired rootVolume spec (machine ${machine_ref}) type=${spec_type} size=${spec_size}GiB throughput=${spec_throughput}MiB/s"
  fi
}

function verify_nodes() {
  local role_label="$1"
  local role_name="$2"
  local expected_throughput="$3"

  local nodes
  nodes=$(oc get nodes -l "${role_label}" -o jsonpath='{.items[*].metadata.name}')
  if [ -z "${nodes}" ]; then
    echo "WARNING: No ${role_name} nodes found, skipping"
    return
  fi

  for node in ${nodes}; do
    local instance_id volume_id volume_type volume_throughput
    local machine_ref

    instance_id=$(oc get node "${node}" -o jsonpath='{.spec.providerID}' | sed 's|.*/||')
    machine_ref=$(oc get node "${node}" -o jsonpath='{.metadata.annotations.machine\.openshift\.io/machine}')
    if [ -z "${instance_id}" ]; then
      echo "WARNING: ${role_name} ${node} has no providerID, skipping"
      log_machine_root_volume_spec "${node}" "${machine_ref}"
      continue
    fi

    # Get root volume ID - each instance has only one root volume
    volume_id=$(aws ec2 describe-instances --instance-ids "${instance_id}" --region "${REGION}" \
      --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" --output text)
    if [ -z "${volume_id}" ]; then
      echo "ERROR: ${role_name} ${node} has no root volume ID"
      FAILURE_SUMMARY+=("${node}: no root volume ID")
      ret=$((ret+1))
      log_machine_root_volume_spec "${node}" "${machine_ref}"
      continue
    fi

    # Get volume information
    volume_type=$(aws ec2 describe-volumes --volume-ids "${volume_id}" --region "${REGION}" \
      --query 'Volumes[0].VolumeType' --output text)
    volume_throughput=$(aws ec2 describe-volumes --volume-ids "${volume_id}" --region "${REGION}" \
      --query 'Volumes[0].Throughput' --output text)

    # Check throughput if expected
    if [[ -n "${expected_throughput}" ]]; then
      if [ "${volume_throughput}" -ne "${expected_throughput}" ]; then
        echo "ERROR: ${node} volume ${volume_id} throughput ${volume_throughput} differs from expected ${expected_throughput}"
        FAILURE_SUMMARY+=("${node}: throughput ${volume_throughput}")
        ret=$((ret+1))
        continue
      else
        echo "PASS: ${node} volume ${volume_id} throughput=${volume_throughput}MiB/s (expected=${expected_throughput}MiB/s)"
      fi
    else
      echo "INFO: ${node} volume ${volume_id} type=${volume_type} throughput=${volume_throughput}MiB/s (no throughput check required)"
    fi
  done
}

echo "-------------------------------------------------------------"
echo "Checking root volumes"
echo "-------------------------------------------------------------"

# Check worker nodes throughput if worker compute pool exists in install-config
# Exclude edge nodes which may also have worker label
if [[ -n "${EXPECTED_COMPUTE_THROUGHPUT}" ]]; then
  echo "Checking worker nodes throughput"
  verify_nodes "node-role.kubernetes.io/worker,node-role.kubernetes.io/edge!=" "worker" "${EXPECTED_COMPUTE_THROUGHPUT}"
fi

# Check control-plane nodes throughput (always check as they should always exist)
echo "Checking control-plane nodes throughput"
verify_nodes "node-role.kubernetes.io/master" "control-plane" "${EXPECTED_CONTROL_PLANE_THROUGHPUT}"

# Check edge nodes throughput if edge compute pool exists (determined by ENABLE_AWS_EDGE_ZONE)
if [[ -n "${EXPECTED_EDGE_THROUGHPUT}" ]]; then
  echo "Checking edge nodes throughput"
  verify_nodes "node-role.kubernetes.io/edge" "edge" "${EXPECTED_EDGE_THROUGHPUT}"
fi

echo "-------------------------------------------------------------"
echo "Test Summary"
echo "-------------------------------------------------------------"
if [ ${ret} -eq 0 ]; then
  echo "All root volume throughput checks passed."
else
  printf 'Failures:\n'
  printf ' - %s\n' "${FAILURE_SUMMARY[@]}"
fi

exit ${ret}
