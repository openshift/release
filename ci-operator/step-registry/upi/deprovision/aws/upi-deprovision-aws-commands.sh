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

aws cloudformation describe-stack-resources --stack-name "${CLUSTER_NAME}-control-plane" \
    --query 'StackResources[?ResourceType==`AWS::EC2::Instance`].PhysicalResourceId' --output text | sed 's,\t,\n,g' > /tmp/node-provider-IDs
for INDEX in 0 1 2
do
    aws cloudformation describe-stack-resources --stack-name "${CLUSTER_NAME}-compute-${INDEX}" \
    --query 'StackResources[].PhysicalResourceId' --output text | cut -d, -f1 >> /tmp/node-provider-IDs
done

while IFS= read -r i; do
    mkdir -p "${SHARED_DIR}/nodes/${i}"
    queue ${SHARED_DIR}/nodes/$i/console aws ec2 get-console-output --instance-id "${i}"
done < /tmp/node-provider-IDs

for STACK_SUFFIX in compute-2 compute-1 compute-0 control-plane bootstrap proxy security infra vpc
do
    aws cloudformation delete-stack --stack-name "${CLUSTER_NAME}-${STACK_SUFFIX}"
done

s3_bucket_uri=$(head -n 1 ${SHARED_DIR}/s3_bucket_uri)
echo "Deleting bootstrap s3 bucket ${s3_bucket_uri}"
aws s3 rb ${s3_bucket_uri} --force
