#!/bin/bash

set -eux

BUCKET_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

bin/hypershift install --hypershift-image="${HYPERSHIFT_RELEASE_LATEST}" \
--oidc-storage-provider-s3-credentials=${CLUSTER_PROFILE_DIR}/.awscred \
--oidc-storage-provider-s3-bucket-name=${BUCKET_NAME} \
--oidc-storage-provider-s3-region=${HYPERSHIFT_AWS_REGION} \
--private-platform=AWS \
--aws-private-creds=/etc/hypershift-pool-aws-credentials/awsprivatecred \
--aws-private-region="${HYPERSHIFT_AWS_REGION}" \
--external-dns-credentials=${CLUSTER_PROFILE_DIR}/.awscred \
--external-dns-provider=aws \
--external-dns-domain-filter=hypershift-ext.qe.devcluster.openshift.com \
--wait-until-available

echo "" > ${SHARED_DIR}/.awsprivatecred