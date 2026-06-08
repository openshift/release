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

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

CONFIG=${SHARED_DIR}/install-config.yaml
if [ ! -f "${CONFIG}" ] ; then
  echo "No install-config.yaml found, exit now"
  exit 1
fi

function is_empty()
{
    local v="$1"
    if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
        return 0
    fi
    return 1
}

RET=0

ic_platform_confidential=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.cpuOptions.confidentialCompute')
ic_control_plane_confidential=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.cpuOptions.confidentialCompute')
ic_compute_confidential=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.cpuOptions.confidentialCompute')

echo "platform: $ic_platform_confidential"
echo "controlPlane: $ic_control_plane_confidential"
echo "compute: $ic_compute_confidential"

control_plane_confidential=""
compute_confidential=""

if ! is_empty "$ic_platform_confidential"; then
  echo "Found defaultMachinePlatform.cpuOptions.confidentialCompute: $ic_platform_confidential"
  control_plane_confidential="${ic_platform_confidential}"
  compute_confidential="${ic_platform_confidential}"
fi

if ! is_empty "$ic_control_plane_confidential"; then
  echo "Found controlPlane.platform.aws.cpuOptions.confidentialCompute: $ic_control_plane_confidential"
  control_plane_confidential="${ic_control_plane_confidential}"
fi

if ! is_empty "$ic_compute_confidential"; then
  echo "Found compute[0].platform.aws.cpuOptions.confidentialCompute: $ic_compute_confidential"
  compute_confidential="${ic_compute_confidential}"
fi

echo "control_plane_confidential: $control_plane_confidential"
echo "compute_confidential: $compute_confidential"

OUT_MACHINES="$ARTIFACT_DIR"/machines.json
OUT_INSTACNES="$ARTIFACT_DIR"/instances.json

oc get machines.machine.openshift.io -n openshift-machine-api -ojson > "$OUT_MACHINES"
aws --region "${REGION}" ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" > "$OUT_INSTACNES"

function check()
{
  local confidential_compute="$1"
  local role="$2"
  local expect_node expect_instance

  expect_node=$confidential_compute
  if [ "$confidential_compute" == "AMDEncryptedVirtualizationNestedPaging" ]; then
    expect_instance="enabled"
  elif [ "$confidential_compute" == "Disabled" ]; then
    expect_instance="disabled"
  fi

  local o i

  for n in $(jq -r --arg r "$role" '.items[] | select(.metadata.labels["machine.openshift.io/cluster-api-machine-role"] == $r) | .metadata.name' "$OUT_MACHINES");
  do
    o=$(jq -r --arg n "$n" '.items[] | select(.metadata.name == $n) | .spec.providerSpec.value.cpuOptions.confidentialCompute' "$OUT_MACHINES")
    if [ "$o" != "$expect_node" ]; then
      echo "FAIL (node): please check node $n, cpuOptions.confidentialCompute is \"$o\", expect \"$expect_node\""
      RET=$((RET+1))
    else
      echo "PASS (node): $n, $o"
    fi
  done

  for i in $(jq -r --arg r "$role" '.Reservations[].Instances[] | select(.Tags[]? | select(.Key == "Name") | .Value | contains($r)) | .Tags[] | select(.Key == "Name") | .Value' "$OUT_INSTACNES");
  do
    o=$(jq -r --arg i "$i" '.Reservations[].Instances[] | select(.Tags[]? | select(.Key == "Name") | .Value == $i) | .CpuOptions.AmdSevSnp' "$OUT_INSTACNES")
    if [ "$o" != "$expect_instance" ]; then
      echo "FAIL (instance): please check instance $i, CpuOptions.AmdSevSnp is \"$o\", expect \"enabled\""
      RET=$((RET+1))
    else
      echo "PASS (instance): $i, $o"
    fi
  done

}

if [ "$control_plane_confidential" != "" ]; then
  check "$control_plane_confidential" "master"
else
  echo "Skip: ControlPlane confidential computing is not set."
fi


if [ "$compute_confidential" != "" ]; then
  check "$compute_confidential" "worker"
else
  echo "Skip: Compute confidential computing is not set."
fi

exit $RET
