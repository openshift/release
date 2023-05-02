#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function aws_delete_policy()
{
    local aws_region=$1
    local policy_arn=$2
    cmd="aws --region $aws_region iam delete-policy --policy-arn ${policy_arn}"
    run_command "${cmd}" || return 1
    return 0
}


function aws_delete_user()
{
    local aws_region=$1
    local user_name=$2
    local ret_code=0

    echo -e "listing attached policy for user $user_name"
    # detach policy
    attached_policies=$(aws --region $aws_region iam list-attached-user-policies --user-name ${user_name} | jq -r .AttachedPolicies[].PolicyArn)

    for policy_arn in $attached_policies;
    do
        if [ X"$policy_arn" == X"" ]; then
            continue
        fi 
        echo -e "detaching policy: ${policy_arn}"
        cmd="aws --region $aws_region iam detach-user-policy --user-name ${user_name} --policy-arn ${policy_arn}"
        run_command "${cmd}" || ret_code=2
    done

    # delete inline policy
    echo -e "deleting inline policies for user $user_name"
    inline_policies=$(aws --region $aws_region iam list-user-policies --user-name ${user_name} | jq -r .PolicyNames[])
    for policy_name in $inline_policies;
    do
        if [ X"$policy_name" == X"" ]; then
            continue
        fi 
        cmd="aws --region $aws_region iam delete-user-policy --user-name ${user_name} --policy-name ${policy_name} "
        run_command "${cmd}" || ret_code=3
    done
    
    echo -e "deleting access keys for user $user_name"
    access_key_ids=$(aws --region $aws_region iam list-access-keys --user-name ${user_name} | jq -r .AccessKeyMetadata[].AccessKeyId)
    for access_key_id in $access_key_ids;
    do
        if [ X"$access_key_id" == X"" ]; then
            continue
        fi 
        cmd="aws --region $aws_region iam delete-access-key --access-key-id ${access_key_id} --user-name ${user_name}"
        run_command "${cmd}" || ret_code=4
    done

    echo -e "deleting user: ${user_name}"
    cmd="aws --region $aws_region iam delete-user --user-name ${user_name}"
    run_command "${cmd}" || ret_code=5
    
    return $ret_code
}

## delete users
user_name_file="${SHARED_DIR}/aws_user_names"
if [ -e "${user_name_file}" ]; then
    for user_name in `cat ${user_name_file}`; do
        if [ X"$user_name" == X"" ]; then
            continue
        fi
        echo "Deleting AWS IAM user: ${user_name}"
        aws_delete_user $REGION $user_name || echo "ERROR: delete user ${user_name}"
    done
else
    echo "${user_name_file} is missing."
fi


## delete policies
policy_arn_file="${SHARED_DIR}/aws_policy_arns"
if [ -e "${policy_arn_file}" ]; then
    for policy_arn in `cat ${policy_arn_file}`; do
        if [ X"$policy_arn" == X"" ]; then
            continue
        fi
        echo "Deleting AWS IAM policy: ${policy_arn}"
        aws_delete_policy $REGION $policy_arn || echo "ERROR: delete policy ${policy_arn}"
    done
else
    echo "${policy_arn_file} is missing."
fi

exit 0


