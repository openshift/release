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

ret=0
output=$(mktemp)

# installer does not create role
for nodetype in worker master;
do
  role_name=${INFRA_ID}-${nodetype}-role
  aws --region $REGION iam get-role --role-name ${role_name} > ${output} 2>&1 || true
  if grep "The role with name ${role_name} cannot be found" ${output}; then
    echo "PASS: ${role_name} does not exist."
  else
    echo "FAIL: ${role_name} was found."
    ret=$((ret+1))
  fi
done

echo $ret

# the correct iam role was used
master_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-master*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $2}')
worker_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-worker*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $2}')

master_role=$(aws --region $REGION iam get-instance-profile --instance-profile-name ${master_profile} | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $2}')
worker_role=$(aws --region $REGION iam get-instance-profile --instance-profile-name ${worker_profile} | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $2}')

echo "Master: profile: ${master_profile}, role: ${master_role}"
echo "Worker: profile: ${worker_profile}, role: ${worker_role}"

ic_platform_role=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.iamRole')
ic_control_plane_role=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.iamRole')
ic_compute_role=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.iamRole')
echo "Install config: platform: ${ic_platform_role}, control plane: ${ic_control_plane_role}, compute: ${ic_compute_role}"

if [[ "${ic_platform_role}" != "" ]]; then
  # custom IAM role
  if [[ "${master_role}" != "${ic_platform_role}" ]] || [[ "${worker_role}" != "${ic_platform_role}" ]]; then
      echo "FAIL: Platform IAM role mismatch: current: ${master_role}, ${worker_role}, expect: ${ic_platform_role}"
      ret=$((ret+1))
  else
      echo "PASS: Platform IAM role (custom)"
  fi
else
  echo "SKIP: No platform IAM role was configured."
fi

if [[ "${ic_control_plane_role}" != "" ]]; then
    # custom IAM role
    if [[ "${master_role}" != "${ic_control_plane_role}" ]]; then
        echo "FAIL: Control-plane IAM role mismatch: current: ${master_role}, expect: ${ic_control_plane_role}"
        ret=$((ret+1))
    else
        echo "PASS: Control-plane IAM role (custom)"
    fi
else
    echo "SKIP: No Control-plane IAM role was configured."
fi


if [[ "${ic_compute_role}" != "" ]]; then
    # custom IAM role
    if [[ "${worker_role}" != "${ic_compute_role}" ]]; then
        echo "FAIL: Compute IAM role mismatch: current: ${worker_role}, expect: ${ic_compute_role}"
        ret=$((ret+1))
    else
        echo "PASS: Compute IAM role (custom)"
    fi
else
    echo "SKIP: No Compute IAM role was configured."
fi

# check role tag
aws --region $REGION iam get-role --role-name ${master_role} --output text > $output
if grep -iE "TAGS.*kubernetes.io/cluster/${INFRA_ID}" $output; then
  echo "FAIL: tag check ${master_role}: kubernetes.io/cluster/${INFRA_ID} tag was attactehd"
  cat $output
  ret=$((ret+1))
else
  echo "PASS: tag check ${master_role}"
fi

aws --region $REGION iam get-role --role-name ${worker_role} --output text > $output
if grep -iE "TAGS.*kubernetes.io/cluster/${INFRA_ID}" $output; then
  echo "FAIL: tag check ${worker_role}: kubernetes.io/cluster/${INFRA_ID} tag was attactehd"
  cat $output
  ret=$((ret+1))
else
  echo "PASS: tag check ${worker_role}"
fi

exit $ret