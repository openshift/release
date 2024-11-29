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


REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
CONFIG=${SHARED_DIR}/install-config.yaml
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"


function is_empty()
{
    local v="$1"
    if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
        return 0
    fi
    return 1
}

function has_tags() {
  local txt="$1"
  if grep -iE "TAGS.*kubernetes.io/cluster/${INFRA_ID}" "$txt"; then
    return 0
  fi
  return 1
}

function has_shared_tags() {
  local txt="$1"
  if grep -iE "TAGS.*kubernetes.io/cluster/${INFRA_ID}.*shared" "$txt"; then
    return 0
  fi
  return 1
}

ret=0
output=$(mktemp)

ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)

echo "-------------------------------------------------------------"
echo "Roles used by cluster"
echo "-------------------------------------------------------------"

control_plane_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-master*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $2}')
compute_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-worker*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $2}')

control_plane_role=$(aws --region $REGION iam get-instance-profile --instance-profile-name ${control_plane_profile} | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $2}')
compute_role=$(aws --region $REGION iam get-instance-profile --instance-profile-name ${compute_profile} | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $2}')

control_plane_role_output=$(mktemp)
compute_role_output=$(mktemp)

aws --region $REGION iam get-role --role-name ${control_plane_role} --output text >$control_plane_role_output
aws --region $REGION iam get-role --role-name ${compute_role} --output text >$compute_role_output

echo "Control plane: profile: ${control_plane_profile}, role: ${control_plane_role}"
cat ${control_plane_role_output}
echo "Compute: profile: ${compute_profile}, role: ${compute_role}"
cat ${compute_role_output}

echo "-------------------------------------------------------------"
echo "Roles configured in install-config.yaml"
echo "-------------------------------------------------------------"

ic_platform_role=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.iamRole')
ic_control_plane_role=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.iamRole')
ic_compute_role=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.iamRole')
echo "Install config: platform: ${ic_platform_role}, control plane: ${ic_control_plane_role}, compute: ${ic_compute_role}"

echo "-------------------------------------------------------------"
echo "Expected roles"
echo "-------------------------------------------------------------"

expected_control_plane_role=""
expected_compute_role=""

if ! is_empty "$ic_platform_role"; then
  echo "platform.aws.defaultMachinePlatform.iamRole was found: ${ic_platform_role}"
  expected_control_plane_role="${ic_platform_role}"
  expected_compute_role="${ic_platform_role}"
fi

if ! is_empty "$ic_control_plane_role"; then
  echo "controlPlane.platform.aws.iamRole was found: ${ic_control_plane_role}"
  expected_control_plane_role="${ic_control_plane_role}"
fi

if ! is_empty "$ic_compute_role"; then
  echo "compute[0].platform.aws.iamRole was found: ${ic_compute_role}"
  expected_compute_role="${ic_compute_role}"
fi

echo "expected_control_plane_role: $expected_control_plane_role"
echo "expected_compute_role: $expected_compute_role"


echo "-------------------------------------------------------------"
echo "Checking role: control plane"
echo "-------------------------------------------------------------"

if [[ ${expected_control_plane_role} != "" ]]; then

  role_name=${INFRA_ID}-master-role
  aws --region $REGION iam get-role --role-name ${role_name} > ${output} 2>&1 || true
  if grep "The role with name ${role_name} cannot be found" ${output}; then
    echo "PASS: ${role_name} does not exist."
  else
    echo "FAIL: ${role_name} was found."
    ret=$((ret+1))
  fi

  if [[ "${control_plane_role}" != "${expected_control_plane_role}" ]]; then  
    echo "FAIL: Control plane IAM role mismatch: current: ${control_plane_role}, expect: ${expected_control_plane_role}"
    ret=$((ret+1))
  else
    echo "PASS: Control plane IAM role"
  fi

  # check role tag
  # for 4.16 and above, shared tag is attached to BYO-Role, see https://github.com/openshift/installer/pull/8688
  # for 4.15 and below, no tag is attached to BYO-Role
  if ((ocp_minor_version >= 16)); then
    if ! has_shared_tags ${control_plane_role_output}; then
      echo "FAIL: tag check: No kubernetes.io/cluster/${INFRA_ID}:shared was found ${control_plane_role}"
      ret=$((ret + 1))
    else
      echo "PASS: tag check: ${control_plane_role}"
    fi
  else
    if has_tags ${control_plane_role_output}; then
      echo "FAIL: tag check: ${control_plane_role}: kubernetes.io/cluster/${INFRA_ID} tag was attactehd"
      ret=$((ret + 1))
    else
      echo "PASS: tag check: ${control_plane_role}"
    fi

  fi

else
  echo "SKIP: No IAM role was configured for control plane nodes."
fi

echo "-------------------------------------------------------------"
echo "Checking role: compute"
echo "-------------------------------------------------------------"

if [[ ${expected_compute_role} != "" ]]; then

  role_name=${INFRA_ID}-worker-role
  aws --region $REGION iam get-role --role-name ${role_name} > ${output} 2>&1 || true
  if grep "The role with name ${role_name} cannot be found" ${output}; then
    echo "PASS: ${role_name} does not exist."
  else
    echo "FAIL: ${role_name} was found."
    ret=$((ret+1))
  fi

  if [[ "${compute_role}" != "${expected_compute_role}" ]]; then
    echo "FAIL: Compute IAM role mismatch: current: ${compute_role}, expect: ${expected_compute_role}"
    ret=$((ret + 1))
  else
    echo "PASS: Compute IAM role"
  fi

  # check role tag
  # for 4.16 and above, shared tag is attached to BYO-Role, see https://github.com/openshift/installer/pull/8688
  # for 4.15 and below, no tag is attached to BYO-Role
  if ((ocp_minor_version >= 16)); then
    if ! has_shared_tags ${compute_role_output}; then
      echo "FAIL: tag check: No kubernetes.io/cluster/${INFRA_ID}:shared was found ${compute_role}"
      ret=$((ret + 1))
    else
      echo "PASS: tag check: ${compute_role}"
    fi
  else
    if has_tags ${compute_role_output}; then
      echo "FAIL: tag check: ${compute_role}: kubernetes.io/cluster/${INFRA_ID} tag was attactehd"
      ret=$((ret + 1))
    else
      echo "PASS: tag check: ${compute_role}"
    fi
  fi
else
  echo "SKIP: No IAM role was configured for compute nodes."
fi

exit $ret
