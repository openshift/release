#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

function cleanup() {
  for child in $( jobs -p ); do
    kill "${child}"
  done
  wait
}
trap cleanup EXIT

export EVENTUALLY_VERBOSE="false"

EXTERNAL_DNS_ARGS=""
if [[ "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN:-}" != "" ]]; then
  EXTERNAL_DNS_ARGS="--e2e.external-dns-domain=${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"
fi

if [[ "${POD_SECURITY_ADMISSION_ANNOTATION}" == "true" ]]; then
  AKS_ANNOTATIONS="hypershift.openshift.io/pod-security-admission-label-override=baseline"
fi

if [[ -n "$HYPERSHIFT_MANAGED_SERVICE" ]]; then
    export MANAGED_SERVICE="$HYPERSHIFT_MANAGED_SERVICE"
fi

hack/ci-test-e2e.sh -test.v \
  -test.run='^TestCreateCluster.*|^TestNodePool$' \
  -test.parallel=20 \
  --e2e.platform=Azure \
  --e2e.azure-credentials-file=/etc/hypershift-ci-jobs-azurecreds/credentials.json \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.base-domain=hypershift.azure.devcluster.openshift.com \
  --e2e.azure-location=${HYPERSHIFT_AZURE_LOCATION} \
    ${EXTERNAL_DNS_ARGS:-} \
    ${AKS_ANNOTATIONS:-} \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" &
wait $!