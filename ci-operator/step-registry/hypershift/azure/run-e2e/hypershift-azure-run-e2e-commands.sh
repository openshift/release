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

AKS_ANNOTATIONS=""
if [[ "${AKS}" == "true" ]]; then
AKS_ANNOTATIONS="--e2e.annotations hypershift.openshift.io/pod-security-admission-label-override=baseline \
  --e2e.annotations hypershift.openshift.io/certified-operators-catalog-image=registry.redhat.io/redhat/certified-operator-index@sha256:fc68a3445d274af8d3e7d27667ad3c1e085c228b46b7537beaad3d470257be3e \
  --e2e.annotations hypershift.openshift.io/community-operators-catalog-image=registry.redhat.io/redhat/community-operator-index@sha256:4a2e1962688618b5d442342f3c7a65a18a2cb014c9e66bb3484c687cfb941b90 \
  --e2e.annotations hypershift.openshift.io/redhat-marketplace-catalog-image=registry.redhat.io/redhat/redhat-marketplace-index@sha256:ed22b093d930cfbc52419d679114f86bd588263f8c4b3e6dfad86f7b8baf9844 \
  --e2e.annotations hypershift.openshift.io/redhat-operators-catalog-image=registry.redhat.io/redhat/redhat-operator-index@sha256:59b14156a8af87c0c969037713fc49be7294401b10668583839ff2e9b49c18d6"
fi


hack/ci-test-e2e.sh -test.v \
  -test.run='^TestCreateCluster.*|^TestNodePool$' \
  -test.parallel=20 \
  --e2e.platform=Azure \
  --e2e.azure-credentials-file=/etc/hypershift-ci-jobs-azurecreds/credentials.json \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.base-domain=hypershift.azure.devcluster.openshift.com \
    ${EXTERNAL_DNS_ARGS:-} \
    ${AKS_ANNOTATIONS:-} \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.external-dns-domain=service.hypershift.azure.devcluster.openshift.com \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" &
wait $!