#!/bin/bash
function queue() {
    local TARGET="${1}"
    shift
    local LIVE
    LIVE="$(jobs | wc -l)"
    while [[ "${LIVE}" -ge 45 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
    done
    echo "${@}"
    if [[ -n "${FILTER:-}" ]]; then
    "${@}" | "${FILTER}" >"${TARGET}" &
    else
    "${@}" >"${TARGET}" &
    fi
}

set +e
export PATH=$PATH:/tmp/shared
AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_SHARED_CREDENTIALS_FILE

echo "Deprovisioning cluster ..."
export PATH="${HOME}/.local/bin:${PATH}"

AWS_DEFAULT_REGION=$(cat ${SHARED_DIR}/AWS_REGION)  # CLI prefers the former
export AWS_DEFAULT_REGION
CLUSTER_NAME=$(cat ${SHARED_DIR}/CLUSTER_NAME)


for STACK_SUFFIX in $DELETE_STACKS_SUFFIX
do
    aws cloudformation delete-stack --stack-name "${CLUSTER_NAME}-${STACK_SUFFIX}"
done
