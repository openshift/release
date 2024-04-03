#!/bin/bash

set -eux

EXTRA_ARGS=""
HCP_CLI="bin/hypershift"
OPERATOR_IMAGE=$HYPERSHIFT_RELEASE_LATEST
if [[ $HO_MULTI == "true" ]]; then
  OPERATOR_IMAGE="quay.io/acm-d/rhtap-hypershift-operator:latest"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  mkdir /tmp/hs-cli
  oc image extract quay.io/acm-d/rhtap-hypershift-operator:latest --path /usr/bin/hypershift:/tmp/hs-cli --registry-config=/tmp/.dockerconfigjson --filter-by-os="linux/amd64"
  chmod +x /tmp/hs-cli/hypershift
  HCP_CLI="/tmp/hs-cli/hypershift"
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
  "${HCP_CLI}" install --hypershift-image="${OPERATOR_IMAGE}" \
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
  "${HCP_CLI}" install --hypershift-image="${OPERATOR_IMAGE}" \
  --platform-monitoring=All \
  --enable-ci-debug-output \
  --wait-until-available \
  ${EXTRA_ARGS}
fi