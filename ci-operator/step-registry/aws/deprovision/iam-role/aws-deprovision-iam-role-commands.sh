#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'delete_all' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
CONFIG=${SHARED_DIR}/install-config.yaml

function is_empty()
{
    local v="$1"
    if [[ "$v" == "" ]] || [[ "$v" == "null" ]]; then
        return 0
    fi
    return 1
}

function aws_delete_role() 
{
    local aws_region=$1
    local role_name=$2

    echo -e "deleteing role: $role_name"
    # detach policy
    attached_policies=$(aws --region $aws_region iam list-attached-role-policies --role-name ${role_name} | jq -r .AttachedPolicies[].PolicyArn)
    echo -e "getting policies ..."
    for policy_arn in $attached_policies;
    do
        if [ X"$policy_arn" == X"" ]; then
            continue
        fi 
        echo -e "detaching policy: ${policy_arn}"
        aws --region $aws_region iam detach-role-policy --role-name ${role_name} --policy-arn ${policy_arn} || return 1
    done

    # delete inline policy
    inline_policies=$(aws --region $aws_region iam list-role-policies --role-name ${role_name} | jq -r .PolicyNames[])
    for policy_name in $inline_policies;
    do
        if [ X"$policy_name" == X"" ]; then
            continue
        fi 
        echo -e "deleting inline policy: ${policy_name}"
        aws --region $aws_region iam delete-role-policy --role-name ${role_name} --policy-name ${policy_name} || return 1
    done
    
    echo -e "deleting role: ${role_name}"
    aws --region $aws_region iam delete-role --role-name ${role_name} || return 1

    return 0
}


function delete_all()
{
    echo "Deleting roles ... "
    aws_delete_role $REGION "$(head -n 1 ${SHARED_DIR}/aws_byo_role_name_master)"
    aws_delete_role $REGION "$(head -n 1 ${SHARED_DIR}/aws_byo_role_name_worker)"

    echo "Deleting policy ... "
    aws --region $REGION iam delete-policy --policy-arn "$(head -n 1 ${SHARED_DIR}/aws_byo_policy_arn_master)"
    aws --region $REGION iam delete-policy --policy-arn "$(head -n 1 ${SHARED_DIR}/aws_byo_policy_arn_worker)"
}

master_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-master*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $2}')
worker_profile=$(aws --region $REGION ec2 describe-instances --filters "Name=tag:Name,Values=${INFRA_ID}-worker*" | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn' | sort | uniq | awk -F '/' '{print $2}')

master_role=$(aws --region $REGION iam get-instance-profile --instance-profile-name ${master_profile} | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $2}')
worker_role=$(aws --region $REGION iam get-instance-profile --instance-profile-name ${worker_profile} | jq -r '.InstanceProfile.Roles[0].Arn' | awk -F '/' '{print $2}')

master_policy_arn=$(aws --region $REGION iam list-attached-role-policies --role-name ${master_role} | jq -j '.AttachedPolicies[].PolicyArn')
worker_policy_arn=$(aws --region $REGION iam list-attached-role-policies --role-name ${worker_role} | jq -j '.AttachedPolicies[].PolicyArn')


ic_platform_role=$(yq-go r "${CONFIG}" 'platform.aws.defaultMachinePlatform.iamRole')
ic_control_plane_role=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.iamRole')
ic_compute_role=$(yq-go r "${CONFIG}" 'compute[0].platform.aws.iamRole')

if ! is_empty "$ic_platform_role"; then
    aws --region $REGION iam get-role --role-name ${master_role}
    aws --region $REGION iam get-role --role-name ${worker_role}
    aws --region $REGION iam get-policy --policy-arn ${master_policy_arn}
    aws --region $REGION iam get-policy --policy-arn ${worker_policy_arn}
fi

if ! is_empty "$ic_control_plane_role"; then
    aws --region $REGION iam get-role --role-name ${master_role}
    aws --region $REGION iam get-policy --policy-arn ${master_policy_arn}
fi

if ! is_empty "$ic_compute_role"; then
    aws --region $REGION iam get-role --role-name ${worker_role}
    aws --region $REGION iam get-policy --policy-arn ${worker_policy_arn}
fi
