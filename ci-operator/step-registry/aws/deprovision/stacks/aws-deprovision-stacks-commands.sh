#!/bin/bash

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

REGION=${REGION:-$LEASED_RESOURCE}

# Special setting for C2S/SC2S
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  REGION=$source_region
fi


function delete_stacks()
{
    local stack_list=$1
    for stack_name in `tac ${stack_list}`; do 
        echo "Deleting stack ${stack_name} ..."
        aws --region $REGION cloudformation delete-stack --stack-name "${stack_name}" &
        wait "$!"
        echo "Deleted stack ${stack_name}"

        aws --region $REGION cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
        wait "$!"
        echo "Waited for stack ${stack_name}"
    done
}

echo "Deleting AWS CloudFormation stacks"

stack_list="${SHARED_DIR}/to_be_removed_cf_stack_list"
if [ -e "${stack_list}" ]; then
    echo "Deleting stacks:"
    cat ${stack_list}
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    delete_stacks ${stack_list}
fi

stack_list="${SHARED_DIR}/to_be_removed_cf_stack_list_shared_account"
if [ -e "${stack_list}" ]; then
    echo "Deleting stacks in shared account:"
    cat ${stack_list}
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
    delete_stacks ${stack_list}
fi

exit 0
