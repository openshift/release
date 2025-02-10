#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

if [[ ! -e ${SHARED_DIR}/ipv4_pool_id ]]; then
    echo "no pool id found, exit now."
    exit 1
fi

expect_ipv4_pool_id=$(head -n 1 ${SHARED_DIR}/ipv4_pool_id)
echo "Expected ipv4 pool id: ${expect_ipv4_pool_id}"

cluster_ipv4_pool_id=$(aws --region ${REGION} ec2 describe-addresses \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json | jq -r '.Addresses[].PublicIpv4Pool' | sort | uniq)

echo "Cluster ipv4 pool id: ${cluster_ipv4_pool_id}"

if [[ "${expect_ipv4_pool_id}" != "${cluster_ipv4_pool_id}" ]]; then
    echo "Ipv4 pool id mismatch, exit now."
    exit 1
else
    echo "PASS"
fi

