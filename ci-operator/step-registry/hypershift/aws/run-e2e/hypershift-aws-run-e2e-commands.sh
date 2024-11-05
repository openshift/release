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

REQUEST_SERVING_COMPONENT_TEST="${REQUEST_SERVING_COMPONENT_TEST:-}"
REQUEST_SERVING_COMPONENT_PARAMS=""

if [[ "${REQUEST_SERVING_COMPONENT_TEST:-}" == "true" ]]; then
   REQUEST_SERVING_COMPONENT_PARAMS="--e2e.test-request-serving-isolation \
  --e2e.management-parent-kubeconfig=${MGMT_PARENT_KUBECONFIG} \
  --e2e.management-cluster-namespace=$(cat "${SHARED_DIR}/management_cluster_namespace") \
  --e2e.management-cluster-name=$(cat "${SHARED_DIR}/management_cluster_name")"
fi

PKI_RECONCILIATION_PARAMS=""
if [[ "${DISABLE_PKI_RECONCILIATION:-}" == "true" ]]; then
  PKI_RECONCILIATION_PARAMS="--e2e.disable-pki-reconciliation=true"
fi

AWS_OBJECT_PARAMS=""
if grep -q 'e2e.aws-oidc-s3-bucket-name' <<<"$( bin/test-e2e -h 2>&1 )"; then
  AWS_OBJECT_PARAMS="--e2e.aws-oidc-s3-bucket-name=hypershift-ci-oidc --e2e.aws-kms-key-alias=alias/hypershift-ci"
fi

AWS_MULTI_ARCH_PARAMS=""
if [[ "${AWS_MULTI_ARCH:-}" == "true" ]]; then
  AWS_MULTI_ARCH_PARAMS="--e2e.aws-multi-arch=true"
fi

export EVENTUALLY_VERBOSE="false"

hack/ci-test-e2e.sh -test.v \
  -test.run=${CI_TESTS_RUN:-''} \
  -test.parallel=20 \
  --e2e.aws-credentials-file=/etc/hypershift-pool-aws-credentials/credentials \
  --e2e.aws-zones=us-east-1a,us-east-1b,us-east-1c \
  ${AWS_OBJECT_PARAMS:-} \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.base-domain=ci.hypershift.devcluster.openshift.com \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" \
  ${PKI_RECONCILIATION_PARAMS:-} \
  --e2e.additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)" \
  --e2e.aws-endpoint-access=PublicAndPrivate \
  --e2e.external-dns-domain=service.ci.hypershift.devcluster.openshift.com \
  ${AWS_MULTI_ARCH_PARAMS:-} \
  ${REQUEST_SERVING_COMPONENT_PARAMS:-} &
wait $!
