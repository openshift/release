#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

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


echo "Deleting roles ... "
aws_delete_role $REGION "$(head -n 1 ${SHARED_DIR}/aws_byo_role_name_master)"
aws_delete_role $REGION "$(head -n 1 ${SHARED_DIR}/aws_byo_role_name_worker)"

echo "Deleting policy ... "
aws --region $REGION iam delete-policy --policy-arn "$(head -n 1 ${SHARED_DIR}/aws_byo_policy_arn_master)"
aws --region $REGION iam delete-policy --policy-arn "$(head -n 1 ${SHARED_DIR}/aws_byo_policy_arn_worker)"
