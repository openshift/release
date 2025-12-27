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

if [ ! -f "${CONFIG}" ]; then
  echo "No install-config found, exit now"
  exit 1
fi

function read_install_config() {
  local query="$1"
  yq-go r "${CONFIG}" "${query}" 2>/dev/null || true
}

# Read all root volume type/throughput/iops configurations from install-config.yaml
# worker pool is at compute[0], edge pool is at compute[1]
DEFAULT_TYPE=$(read_install_config 'platform.aws.defaultMachinePlatform.rootVolume.type')
DEFAULT_THROUGHPUT=$(read_install_config 'platform.aws.defaultMachinePlatform.rootVolume.throughput')
DEFAULT_IOPS=$(read_install_config 'platform.aws.defaultMachinePlatform.rootVolume.iops')

CONTROL_PLANE_TYPE=$(read_install_config 'controlPlane.platform.aws.rootVolume.type')
CONTROL_PLANE_THROUGHPUT=$(read_install_config 'controlPlane.platform.aws.rootVolume.throughput')
CONTROL_PLANE_IOPS=$(read_install_config 'controlPlane.platform.aws.rootVolume.iops')

COMPUTE_TYPE=$(read_install_config "compute[0].platform.aws.rootVolume.type")
COMPUTE_THROUGHPUT=$(read_install_config "compute[0].platform.aws.rootVolume.throughput")
COMPUTE_IOPS=$(read_install_config "compute[0].platform.aws.rootVolume.iops")

CONTROL_PLANE_COUNT=$(read_install_config "controlPlane.replicas")
COMPUTE_COUNT=$(read_install_config "compute[0].replicas")

ret=0

VOLS_JSON="${ARTIFACT_DIR}/vols.json"
aws --region "${REGION}" ec2 describe-volumes --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" > "${VOLS_JSON}"

function volume_check() {
  local role=$1
  local expect_type=$2
  local expect_throughput=$3
  local expect_iops=$4
  local expect_count=$5

  echo "Checking ${role} volumes: type=${expect_type}, throughput=${expect_throughput}, iops=${expect_iops}, count=${expect_count}"

  local matched
  matched=$(jq -r --arg r "-${role}-" --arg t "${expect_type}" --argjson tp "${expect_throughput}" --argjson i "${expect_iops}" \
    '[.Volumes[] | select((.Tags[] | (.Key == "Name" and (.Value | contains($r)))) and .Iops == $i and .VolumeType == $t and .Throughput == $tp)] | length' "${VOLS_JSON}")

  if [ "${matched}" != "${expect_count}" ]; then
    echo "ERROR: ${role} volumes mismatch (expected ${expect_count}, got ${matched}). See $(basename "${VOLS_JSON}")"
    ret=$((ret+1))
  else
    echo "PASS: ${role} volumes match expected configuration."
  fi
}

echo "-------------------------------------------------------------"
echo "Checking root volumes (gp3: type/throughput/iops/count)"
echo "-------------------------------------------------------------"

# control-plane (always expected)
EXPECTED_CONTROL_PLANE_TYPE="${CONTROL_PLANE_TYPE:-${DEFAULT_TYPE}}"
EXPECTED_CONTROL_PLANE_THROUGHPUT="${CONTROL_PLANE_THROUGHPUT:-${DEFAULT_THROUGHPUT}}"
EXPECTED_CONTROL_PLANE_IOPS="${CONTROL_PLANE_IOPS:-${DEFAULT_IOPS}}"

if [[ "${EXPECTED_CONTROL_PLANE_TYPE}" == "gp3" && -n "${EXPECTED_CONTROL_PLANE_THROUGHPUT}" && -n "${EXPECTED_CONTROL_PLANE_IOPS}" && -n "${CONTROL_PLANE_COUNT}" ]]; then
  volume_check "master" "${EXPECTED_CONTROL_PLANE_TYPE}" "${EXPECTED_CONTROL_PLANE_THROUGHPUT}" "${EXPECTED_CONTROL_PLANE_IOPS}" "${CONTROL_PLANE_COUNT}"
else
  echo "SKIP: control-plane volumes not fully specified."
fi

# worker pool (compute[0])
EXPECTED_COMPUTE_TYPE="${COMPUTE_TYPE:-${DEFAULT_TYPE}}"
EXPECTED_COMPUTE_THROUGHPUT="${COMPUTE_THROUGHPUT:-${DEFAULT_THROUGHPUT}}"
EXPECTED_COMPUTE_IOPS="${COMPUTE_IOPS:-${DEFAULT_IOPS}}"

if [[ "${EXPECTED_COMPUTE_TYPE}" == "gp3" && -n "${EXPECTED_COMPUTE_THROUGHPUT}" && -n "${EXPECTED_COMPUTE_IOPS}" && -n "${COMPUTE_COUNT}" ]]; then
  volume_check "worker" "${EXPECTED_COMPUTE_TYPE}" "${EXPECTED_COMPUTE_THROUGHPUT}" "${EXPECTED_COMPUTE_IOPS}" "${COMPUTE_COUNT}"
else
  echo "SKIP: worker volumes not fully specified."
fi

# edge pool (compute[1]) only when edge zone is enabled
if [[ "${ENABLE_AWS_EDGE_ZONE}" == "yes" ]]; then
  EDGE_TYPE=$(read_install_config "compute[1].platform.aws.rootVolume.type")
  EDGE_THROUGHPUT=$(read_install_config "compute[1].platform.aws.rootVolume.throughput")
  EDGE_IOPS=$(read_install_config "compute[1].platform.aws.rootVolume.iops")
  EDGE_COUNT=$(read_install_config "compute[1].replicas")

  EXPECTED_EDGE_TYPE="${EDGE_TYPE:-${DEFAULT_TYPE}}"
  EXPECTED_EDGE_THROUGHPUT="${EDGE_THROUGHPUT:-${DEFAULT_THROUGHPUT}}"
  EXPECTED_EDGE_IOPS="${EDGE_IOPS:-${DEFAULT_IOPS}}"

  if [[ "${EXPECTED_EDGE_TYPE}" == "gp3" && -n "${EXPECTED_EDGE_THROUGHPUT}" && -n "${EXPECTED_EDGE_IOPS}" && -n "${EDGE_COUNT}" ]]; then
    volume_check "edge" "${EXPECTED_EDGE_TYPE}" "${EXPECTED_EDGE_THROUGHPUT}" "${EXPECTED_EDGE_IOPS}" "${EDGE_COUNT}"
  else
    echo "SKIP: edge volumes not fully specified or edge zone disabled."
  fi
fi

echo "-------------------------------------------------------------"
echo "Test Summary"
echo "-------------------------------------------------------------"
if [ ${ret} -eq 0 ]; then
  echo "All root volume checks passed."
else
  echo "Some root volume checks failed. See $(basename "${VOLS_JSON}") for details."
fi

exit ${ret}
