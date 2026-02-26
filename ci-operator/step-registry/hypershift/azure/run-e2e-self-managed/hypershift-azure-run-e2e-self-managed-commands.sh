#!/bin/bash

set +x

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

AZURE_WORKLOAD_IDENTITIES_LOCATION="/etc/hypershift-ci-jobs-self-managed-azure-e2e/workload-identities.json"
AZURE_SA_TOKEN_ISSUER_KEY_PATH="/etc/hypershift-ci-jobs-self-managed-azure-e2e/serviceaccount-signer.private"
AZURE_OIDC_ISSUER_URL="https://smazure.blob.core.windows.net/smazure"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

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

N1_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N1} != "${OCP_IMAGE_LATEST}" ]]; then
  N1_NP_VERSION_TEST_ARGS="--e2e.n1-minor-release-image=${OCP_IMAGE_N1}"
fi

N2_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N2} != "${OCP_IMAGE_LATEST}" ]]; then
  N2_NP_VERSION_TEST_ARGS="--e2e.n2-minor-release-image=${OCP_IMAGE_N2}"
fi

EXTERNAL_DNS_ARGS=""
if [[ "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN:-}" != "" ]]; then
  EXTERNAL_DNS_ARGS="--e2e.external-dns-domain=${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"
fi

hack/ci-test-e2e.sh -test.v \
  -test.run=${CI_TESTS_RUN:-} \
  -test.parallel=20 \
  --e2e.platform=Azure \
  --e2e.azure-credentials-file=${AZURE_AUTH_LOCATION} \
  --e2e.azure-workload-identities-file=${AZURE_WORKLOAD_IDENTITIES_LOCATION} \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.base-domain=hcp-sm-azure.azure.devcluster.openshift.com \
  --e2e.azure-location=${HYPERSHIFT_AZURE_LOCATION} \
  --e2e.oidc-issuer-url=${AZURE_OIDC_ISSUER_URL} \
  --e2e.sa-token-issuer-private-key-path=${AZURE_SA_TOKEN_ISSUER_KEY_PATH} \
    ${N1_NP_VERSION_TEST_ARGS:-} \
    ${N2_NP_VERSION_TEST_ARGS:-} \
    ${EXTERNAL_DNS_ARGS:-} \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" &
wait $!
