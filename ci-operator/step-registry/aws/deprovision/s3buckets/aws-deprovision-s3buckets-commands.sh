#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

echo "Deleting s3 bucket of bastion host"

s3_bucket_list="${SHARED_DIR}/to_be_removed_s3_bucket_list"
if [ -e "${s3_bucket_list}" ]; then
    for s3_bucket in `cat ${s3_bucket_list}`; do 
        echo "Deleting s3 bucket ${s3_bucket} ..."
        aws --region $REGION s3 rb ${s3_bucket} --force &
        wait "$!"
        echo "Deleted s3 bucket ${s3_bucket}"
    done
fi
exit 0
