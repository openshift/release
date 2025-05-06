#!/bin/bash

set +x

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

AZURE_MANAGED_IDENTITIES_LOCATION="/etc/hypershift-ci-jobs-azurecreds/managed-identities.json"
AZURE_DATA_PLANE_IDENTITIES_LOCATION="/etc/hypershift-ci-jobs-azurecreds/dataplane-identities.json"
AZURE_SA_TOKEN_ISSUER_KEY_PATH="/etc/hypershift-ci-jobs-azurecreds/serviceaccount-signer.private"
AZURE_OIDC_ISSUER_URL_LOCATION="/etc/hypershift-ci-jobs-azurecreds/oidc-issuer-url.json"
AZURE_OIDC_ISSUER_URL="$(<"${AZURE_OIDC_ISSUER_URL_LOCATION}" jq -r .oidcIssuerURL)"

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

EXTERNAL_DNS_ARGS=""
if [[ "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN:-}" != "" ]]; then
  EXTERNAL_DNS_ARGS="--e2e.external-dns-domain=${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"
fi

if [[ "${AKS}" == "true" ]]; then
  AKS_ANNOTATIONS=""
  HC_ANNOTATIONS_FILE="${SHARED_DIR}/hypershift_hc_annotations"

  if [[ -f "$HC_ANNOTATIONS_FILE" ]]; then
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then
        AKS_ANNOTATIONS+=" --e2e.annotations=${line}"
      fi
    done < "$HC_ANNOTATIONS_FILE"
  fi
fi

if [[ -n "$HYPERSHIFT_MANAGED_SERVICE" ]]; then
    export MANAGED_SERVICE="$HYPERSHIFT_MANAGED_SERVICE"
fi

N1_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N1} != "${OCP_IMAGE_LATEST}" ]]; then
  N1_NP_VERSION_TEST_ARGS="--e2e.n1-minor-release-image=${OCP_IMAGE_N1}"
fi

N2_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N2} != "${OCP_IMAGE_LATEST}" ]]; then
  N2_NP_VERSION_TEST_ARGS="--e2e.n2-minor-release-image=${OCP_IMAGE_N2}"
fi

MI_ARGS=""
if [[ "${AUTH_THROUGH_CERTS}" == "true" ]]; then
  MI_ARGS="--e2e.azure-managed-identities-file=${AZURE_MANAGED_IDENTITIES_LOCATION}"
fi

DP_ARGS=""
if [[ "${AUTH_THROUGH_CERTS}" == "true" ]]; then
  DP_ARGS="--e2e.azure-data-plane-identities-file=${AZURE_DATA_PLANE_IDENTITIES_LOCATION}"
fi

hack/ci-test-e2e.sh -test.v \
  -test.run=${CI_TESTS_RUN:-} \
  -test.parallel=20 \
  --e2e.platform=Azure \
  --e2e.azure-credentials-file=/etc/hypershift-ci-jobs-azurecreds/credentials.json \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.base-domain=hypershift.azure.devcluster.openshift.com \
  --e2e.azure-location=${HYPERSHIFT_AZURE_LOCATION} \
  --e2e.oidc-issuer-url=${AZURE_OIDC_ISSUER_URL} \
  --e2e.sa-token-issuer-private-key-path=${AZURE_SA_TOKEN_ISSUER_KEY_PATH} \
    ${EXTERNAL_DNS_ARGS:-} \
    ${AKS_ANNOTATIONS:-} \
    ${N1_NP_VERSION_TEST_ARGS:-} \
    ${N2_NP_VERSION_TEST_ARGS:-} \
    ${MI_ARGS:-} \
    ${DP_ARGS:-} \
  --e2e.azure-marketplace-publisher "azureopenshift" \
  --e2e.azure-marketplace-offer "aro4" \
  --e2e.azure-marketplace-sku "aro_417" \
  --e2e.azure-marketplace-version "417.94.20240701" \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" &
wait $!