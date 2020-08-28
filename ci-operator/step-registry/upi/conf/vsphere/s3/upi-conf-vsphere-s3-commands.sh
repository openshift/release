#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

HOME=/tmp

export HOME
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_DEFAULT_REGION=us-east-1
export AWS_MAX_ATTEMPTS=7
export AWS_RETRY_MODE=adaptive

cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

if ! command -v aws &> /dev/null
then
    echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
    export PATH="${HOME}/.local/bin:${PATH}"
    easy_install --user pip  # our Python 2.7.5 is even too old for ensurepip
    pip install --user awscli
fi

echo "$(date -u --rfc-3339=seconds) - Create AWS S3 bucket..."

aws s3 mb "s3://${cluster_name}"
echo "$(date -u --rfc-3339=seconds) - Copy bootstrap.ign to bucket..."
aws s3 cp "${SHARED_DIR}/bootstrap.ign" "s3://${cluster_name}"

echo "$(date -u --rfc-3339=seconds) - Create presign url for bootstrap.ign ..."
aws_s3_bootstrap_url=$(aws s3 presign "s3://${cluster_name}/bootstrap.ign")

echo "bootstrap_ignition_url = \"${aws_s3_bootstrap_url}\""
echo "bootstrap_ignition_url = \"${aws_s3_bootstrap_url}\"" >> "${SHARED_DIR}/terraform.tfvars"
exit 0
