#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'delete_all' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CONFIG=${SHARED_DIR}/install-config.yaml

function is_empty() {
  local v="$1"
  if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
    return 0
  fi
  return 1
}

function aws_delete_role() {
  local aws_region=$1
  local role_name=$2

  echo -e "Deleteing role: $role_name"
  # detach policy
  attached_policies=$(aws --region $aws_region iam list-attached-role-policies --role-name ${role_name} | jq -r .AttachedPolicies[].PolicyArn)
  for policy_arn in $attached_policies; do
    echo -e "\tDetaching policy: ${policy_arn}"
    aws --region $aws_region iam detach-role-policy --role-name ${role_name} --policy-arn ${policy_arn} || return 1
  done

  # delete inline policy
  # inline_policies=$(aws --region $aws_region iam list-role-policies --role-name ${role_name} | jq -r .PolicyNames[])
  # for policy_name in $inline_policies; do
  #   echo -e "\tDeleting inline policy: ${policy_name}"
  #   aws --region $aws_region iam delete-role-policy --role-name ${role_name} --policy-name ${policy_name} || return 1
  # done

  aws --region $aws_region iam delete-role --role-name ${role_name} || return 1
  echo -e "\tDeleted."

  return 0
}

function aws_delete_policy() {
  local aws_region=$1
  local policy_arn=$2

  echo -e "Deleting policy: $policy_arn"
  aws --region $aws_region iam delete-policy --policy-arn ${policy_arn}
  echo -e "\tDeleted."

  return 0
}

function delete_all() {
  set +e
  echo "Deleting BYO-IAM resources ..."
  aws_delete_role $REGION "$(head -n 1 ${SHARED_DIR}/aws_byo_role_name_master)"
  aws_delete_role $REGION "$(head -n 1 ${SHARED_DIR}/aws_byo_role_name_worker)"

  aws_delete_policy $REGION "$(head -n 1 ${SHARED_DIR}/aws_byo_policy_arn_master)"
  aws_delete_policy $REGION "$(head -n 1 ${SHARED_DIR}/aws_byo_policy_arn_worker)"
}

echo "Post-check for BYO-IAM resources"

ic_platform_role=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.iamRole')
ic_control_plane_role=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.iamRole')
ic_compute_role=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.iamRole')

if ! is_empty "$ic_platform_role"; then
  aws --region $REGION iam get-role --role-name "${ic_platform_role}"
fi

if ! is_empty "$ic_control_plane_role"; then
  aws --region $REGION iam get-role --role-name "${ic_control_plane_role}"
fi

if ! is_empty "$ic_compute_role"; then
  aws --region $REGION iam get-role --role-name "${ic_compute_role}"
fi
