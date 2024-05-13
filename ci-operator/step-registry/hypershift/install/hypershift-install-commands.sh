#!/bin/bash

set -eux

EXTRA_ARGS=""

OPERATOR_IMAGE=$HYPERSHIFT_RELEASE_LATEST
if [[ $OCP_ARCH == "arm64" ]]; then
  OPERATOR_IMAGE="quay.io/hypershift/hypershift-operator:latest-arm64"
fi

if [ "${ENABLE_HYPERSHIFT_OPERATOR_DEFAULTING_WEBHOOK}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --enable-defaulting-webhook=true"
fi

if [ "${ENABLE_HYPERSHIFT_OPERATOR_VALIDATING_WEBHOOK}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --enable-validating-webhook=true"
fi

if [ "${ENABLE_HYPERSHIFT_CERT_ROTATION_SCALE}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --cert-rotation-scale=20m"
fi

if [ "${CLOUD_PROVIDER}" == "AWS" ]; then
  bin/hypershift install --hypershift-image="${OPERATOR_IMAGE}" \
  --oidc-storage-provider-s3-credentials=/etc/hypershift-pool-aws-credentials/credentials \
  --oidc-storage-provider-s3-bucket-name=hypershift-ci-oidc \
  --oidc-storage-provider-s3-region=us-east-1 \
  --platform-monitoring=All \
  --enable-ci-debug-output \
  --private-platform=AWS \
  --aws-private-creds=/etc/hypershift-pool-aws-credentials/credentials \
  --aws-private-region="${HYPERSHIFT_AWS_REGION}" \
  --external-dns-provider=aws \
  --external-dns-credentials=/etc/hypershift-pool-aws-credentials/credentials \
  --external-dns-domain-filter=service.ci.hypershift.devcluster.openshift.com \
  --wait-until-available \
  ${EXTRA_ARGS}
else
  bin/hypershift install --hypershift-image="${OPERATOR_IMAGE}" \
  --platform-monitoring=All \
  --enable-ci-debug-output \
  --wait-until-available \
  ${EXTRA_ARGS}
fi