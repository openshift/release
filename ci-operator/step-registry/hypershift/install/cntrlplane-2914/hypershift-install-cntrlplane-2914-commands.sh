#!/bin/bash

set -eux

# CNTRLPLANE-2914: Hardcoded custom HyperShift operator image
OPERATOR_IMAGE="quay.io/wangke19/hypershift:CNTRLPLANE-2914"

echo "Installing HyperShift operator with hardcoded image: ${OPERATOR_IMAGE}"

# Extract CLI from custom image
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
mkdir -p /tmp/hs-cli
oc image extract ${OPERATOR_IMAGE} --path /usr/bin/hypershift:/tmp/hs-cli --registry-config=/tmp/.dockerconfigjson --filter-by-os="linux/amd64"
chmod +x /tmp/hs-cli/hypershift

EXTRA_ARGS=""

if [ "${ENABLE_HYPERSHIFT_CERT_ROTATION_SCALE:-false}" = "true" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --cert-rotation-scale=20m"
fi

# Install HyperShift operator with hardcoded image
/tmp/hs-cli/hypershift install \
  --hypershift-image ${OPERATOR_IMAGE} \
  --oidc-storage-provider-s3-bucket-name hypershift-ci-oidc \
  --oidc-storage-provider-s3-credentials /etc/hypershift-pool-aws-credentials/credentials \
  --oidc-storage-provider-s3-region us-east-1 \
  --platform-monitoring=All \
  --enable-ci-debug-output \
  --private-platform=AWS \
  --aws-private-creds /etc/hypershift-pool-aws-credentials/credentials \
  --aws-private-region us-east-1 \
  --external-dns-provider=aws \
  --external-dns-credentials /etc/hypershift-pool-aws-credentials/credentials \
  --external-dns-domain-filter=service.ci.hypershift.devcluster.openshift.com \
  ${EXTRA_ARGS} \
  --wait-until-available

echo "Verifying HyperShift operator installation"
oc get deployment -n hypershift operator -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""
echo "HyperShift operator installation complete"
