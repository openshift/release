#!/bin/bash

set -eux

OPERATOR_IMAGE=$HYPERSHIFT_RELEASE_LATEST
if [[ $OCP_ARCH == "arm64" ]]; then
  OPERATOR_IMAGE="quay.io/hypershift/hypershift-operator:latest-arm64"
fi

bin/hypershift install --hypershift-image="${OPERATOR_IMAGE}" \
--oidc-storage-provider-s3-credentials=/etc/hypershift-pool-aws-credentials/credentials \
--oidc-storage-provider-s3-bucket-name=hypershift-ci-oidc \
--oidc-storage-provider-s3-region=us-east-1 \
--private-platform=AWS \
--aws-private-creds=/etc/hypershift-pool-aws-credentials/credentials \
--aws-private-region="${HYPERSHIFT_AWS_REGION}" \
--external-dns-provider=aws \
--external-dns-credentials=/etc/hypershift-pool-aws-credentials/credentials \
--external-dns-domain-filter=service.ci.hypershift.devcluster.openshift.com \
--wait-until-available