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

check_e2e_flag() {
  grep -q "$1" <<<"$( bin/test-e2e -h 2>&1 )"
  return $?
}

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
if check_e2e_flag 'e2e.aws-oidc-s3-bucket-name'; then
  AWS_OBJECT_PARAMS="--e2e.aws-oidc-s3-bucket-name=hypershift-ci-oidc --e2e.aws-kms-key-alias=alias/hypershift-ci"
fi

AWS_MULTI_ARCH_PARAMS=""
if [[ "${AWS_MULTI_ARCH:-}" == "true" ]]; then
  AWS_MULTI_ARCH_PARAMS="--e2e.aws-multi-arch=true"
fi

N1_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N1} != "${OCP_IMAGE_LATEST}" ]]; then
  N1_NP_VERSION_TEST_ARGS="--e2e.n1-minor-release-image=${OCP_IMAGE_N1}"
fi

N2_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N2} != "${OCP_IMAGE_LATEST}" ]]; then
  N2_NP_VERSION_TEST_ARGS="--e2e.n2-minor-release-image=${OCP_IMAGE_N2}"
fi

RUN_UPGRADE_PARAM=""
if [[ "${RUN_UPGRADE_TEST:-}" == "true" ]] && check_e2e_flag "upgrade.run-tests" ; then
  RUN_UPGRADE_PARAM="--upgrade.run-tests --e2e.private-platform=AWS --e2e.ho-enable-ci-debug-output=true --e2e.hypershift-operator-latest-image=${CI_HYPERSHIFT_OPERATOR}"
fi

OAUTH_EXTERNAL_OIDC_PARAM=""
if [[ "${OAUTH_EXTERNAL_OIDC_PROVIDER}" != "" ]]; then
  case "${OAUTH_EXTERNAL_OIDC_PROVIDER}" in
    "keycloak")
      # idp-external-oidc-keycloak-server-commands.sh
      source "${SHARED_DIR}/runtime_env"
      OAUTH_EXTERNAL_OIDC_PARAM="--e2e.external-oidc-provider=${OAUTH_EXTERNAL_OIDC_PROVIDER} \
      --e2e.external-oidc-cli-client-id=${KEYCLOAK_CLI_CLIENT_ID} \
      --e2e.external-oidc-console-client-id=${CONSOLE_CLIENT_ID} \
      --e2e.external-oidc-issuer-url=${KEYCLOAK_ISSUER} \
      --e2e.external-oidc-console-secret=${CONSOLE_CLIENT_SECRET_VALUE} \
      --e2e.external-oidc-ca-bundle-file=${KEYCLOAK_CA_BUNDLE_FILE}  \
      --e2e.external-oidc-test-users=${KEYCLOAK_TEST_USERS}"
      ;;
    "azure")
      #todo
      echo "azure is not supported yet"
      exit 1
      ;;
    *)
      echo "unsupported OAUTH_EXTERNAL_OIDC_PROVIDER ${OAUTH_EXTERNAL_OIDC_PROVIDER}"
      exit 1
      ;;
  esac
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
  ${N1_NP_VERSION_TEST_ARGS:-} \
  ${N2_NP_VERSION_TEST_ARGS:-} \
  --e2e.additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)" \
  --e2e.aws-endpoint-access=PublicAndPrivate \
  --e2e.external-dns-domain=service.ci.hypershift.devcluster.openshift.com \
  ${AWS_MULTI_ARCH_PARAMS:-} \
  ${REQUEST_SERVING_COMPONENT_PARAMS:-} \
  ${OAUTH_EXTERNAL_OIDC_PARAM:-} \
  ${RUN_UPGRADE_PARAM} &
wait $!
