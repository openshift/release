#!/bin/bash

set -eux

BUCKET_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

bin/hypershift install --hypershift-image="${HYPERSHIFT_RELEASE_LATEST}" \
--oidc-storage-provider-s3-credentials=${CLUSTER_PROFILE_DIR}/.awscred \
--oidc-storage-provider-s3-bucket-name=${BUCKET_NAME} \
--oidc-storage-provider-s3-region=${HYPERSHIFT_AWS_REGION} \
--enable-validating-webhook \
--private-platform=AWS \
--aws-private-creds=${SHARED_DIR}/.awsprivatecred \
--aws-private-region="${HYPERSHIFT_AWS_REGION}" \
--wait-until-available

echo "" > ${SHARED_DIR}/.awsprivatecred