#!/bin/bash
set +e
AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_SHARED_CREDENTIALS_FILE

echo "Deprovisioning cluster ..."
export PATH="${HOME}/.local/bin:${PATH}"

AWS_DEFAULT_REGION=$(cat ${SHARED_DIR}/AWS_REGION)  # CLI prefers the former
export AWS_DEFAULT_REGION
CLUSTER_NAME=$(cat ${SHARED_DIR}/CLUSTER_NAME)
for STACK_SUFFIX in compute-2 compute-1 compute-0 control-plane bootstrap proxy security infra vpc
do
    aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}-${STACK_SUFFIX}" &&
    aws cloudformation delete-stack --stack-name "${CLUSTER_NAME}-${STACK_SUFFIX}" &&
    aws cloudformation wait stack-delete-complete --stack-name "${CLUSTER_NAME}-${STACK_SUFFIX}" || true
done
