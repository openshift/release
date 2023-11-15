#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

bucket_name=${INFRA_ID}-bootstrap
key_name="bootstrap.ign"

echo "Checking if s3://${bucket_name}/${key_name} exists"
aws --region ${REGION} s3 ls s3://${bucket_name}/${key_name}
