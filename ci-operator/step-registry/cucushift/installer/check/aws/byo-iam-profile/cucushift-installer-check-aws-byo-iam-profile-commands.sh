#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function is_empty()
{
    local v="$1"
    if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
        return 0
    fi
    return 1
}

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
CONFIG=${SHARED_DIR}/install-config.yaml
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

ret=0
output=$(mktemp)

# installer does not create profile
for nodetype in worker master;
do
  profile_name=${INFRA_ID}-${nodetype}-profile
  aws --region $REGION iam get-instance-profile --instance-profile-name ${profile_name} > ${output} 2>&1 || true
  if grep "Instance Profile ${profile_name} cannot be found" ${output}; then
    echo "PASS: ${profile_name} does not exist."
  else
    echo "FAIL: ${profile_name} was found."
    ret=$((ret+1))
  fi
done

# the correct iam profile was used
control_plane_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-master*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $2}')
compute_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-worker*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $2}')

echo "Control plane: profile: ${control_plane_profile}"
echo "Compute: profile: ${compute_profile}"

ic_platform_profile=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.iamProfile')
ic_control_plane_profile=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.iamProfile')
ic_compute_profile=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.iamProfile')
echo "Install config: platform: ${ic_platform_profile}, control plane: ${ic_control_plane_profile}, compute: ${ic_compute_profile}"

expected_control_plane_profile=""
expected_compute_profile=""

if ! is_empty "$ic_platform_profile"; then
  echo "platform.aws.defaultMachinePlatform.iamProfile was found: ${ic_platform_profile}"
  expected_control_plane_profile="${ic_platform_profile}"
  expected_compute_profile="${ic_platform_profile}"
fi

if ! is_empty "$ic_control_plane_profile"; then
  echo "controlPlane.platform.aws.iamProfile was found: ${ic_control_plane_profile}"
  expected_control_plane_profile="${ic_control_plane_profile}"
fi

if ! is_empty "$ic_compute_profile"; then
  echo "compute[0].platform.aws.iamProfile was found: ${ic_compute_profile}"
  expected_compute_profile="${ic_compute_profile}"
fi

if [[ ${expected_control_plane_profile} != "" ]]; then
  if [[ "${control_plane_profile}" != "${expected_control_plane_profile}" ]]; then  
    echo "FAIL: Control plane IAM profile mismatch: current: ${control_plane_profile}, expect: ${expected_control_plane_profile}"
    ret=$((ret+1))
  else
    echo "PASS: Control plane IAM profile"
  fi
else
  echo "SKIP: No IAM profile was configured for control plane nodes."
fi

if [[ ${expected_compute_profile} != "" ]]; then
  if [[ "${compute_profile}" != "${expected_compute_profile}" ]]; then
    echo "FAIL: Compute IAM profile mismatch: current: ${compute_profile}, expect: ${expected_compute_profile}"
    ret=$((ret + 1))
  else
    echo "PASS: Compute IAM profile"
  fi
else
  echo "SKIP: No IAM profile was configured for compute nodes."
fi

# check profile tag
function has_shared_tags() {
  local txt="$1"
  if grep -iE "TAGS.*kubernetes.io/cluster/${INFRA_ID}.*shared" "$txt"; then
    return 0
  fi
  return 1
}

control_plane_profile_output=$(mktemp)
compute_profile_output=$(mktemp)

aws --region $REGION iam get-instance-profile --instance-profile-name ${control_plane_profile} --output text >$control_plane_profile_output
aws --region $REGION iam get-instance-profile --instance-profile-name ${compute_profile} --output text >$compute_profile_output

echo "Profile: ${control_plane_profile}"
cat ${control_plane_profile_output}
echo "Profile: ${compute_profile}"
cat ${compute_profile_output}

if ! has_shared_tags ${control_plane_profile_output}; then
  echo "FAIL: tag check: No kubernetes.io/cluster/${INFRA_ID}:shared was found ${control_plane_profile}"
  ret=$((ret + 1))
else
  echo "PASS: tag check: ${control_plane_profile}"
fi

if ! has_shared_tags ${compute_profile_output}; then
  echo "FAIL: tag check: No kubernetes.io/cluster/${INFRA_ID}:shared was found ${compute_profile}"
  ret=$((ret + 1))
else
  echo "PASS: tag check: ${compute_profile}"
fi

exit $ret
