#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
trap_subprocesses_on_term

function delete_stacks() {
    local stack_list=$1
    while read -r line; do
        region=$(echo "${line}" | cut -f1 -d " ")
        name=$(echo "${line}" | cut -f2 -d " ")

        # shellcheck disable=SC2016
        if aws --region "${region}" cloudformation describe-stacks --stack-name "${name}" \
          --query 'Stacks[].Outputs[?OutputKey == `InstanceId`].OutputValue' --output text; then
            echo "Deleting stack ${name} in region ${region}..."
            aws --region "${region}" cloudformation delete-stack --stack-name "${name}" &
            wait "$!"
            aws --region "${region}" cloudformation wait stack-delete-complete --stack-name "${name}" &
            wait "$!"
            echo "Deleted stack ${name} in region ${region}"
            aws --region "${region}" cloudformation describe-stacks --stack-name "${name}" || true
        else
            echo "Stack ${name} in region ${region} does not exist"
        fi
    done < "${stack_list}"
}

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

echo "Deleting AWS CloudFormation stacks"

stack_list="${SHARED_DIR}/to_be_removed_cf_stack_list"
if [ -e "${stack_list}" ]; then
    echo "Deleting stacks:"
    cat "${stack_list}"
    delete_stacks "${stack_list}"
fi

exit 0
