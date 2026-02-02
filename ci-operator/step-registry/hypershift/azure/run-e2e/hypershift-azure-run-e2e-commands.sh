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

AZURE_KMS_INFO_LOCATION="/etc/hypershift-ci-jobs-azurecreds/aks-kms-info.json"
AKS_KMS_KEY="$(jq -r '."aks-kms-key"' "${AZURE_KMS_INFO_LOCATION}")"
AKS_KMS_CREDENTIALS_SECRET="$(jq -r '."aks-kms-credentials-secret"' "${AZURE_KMS_INFO_LOCATION}")"

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

N3_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N3} != "${OCP_IMAGE_LATEST}" ]]; then
  N3_NP_VERSION_TEST_ARGS="--e2e.n3-minor-release-image=${OCP_IMAGE_N3}"
fi

N4_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N4} != "${OCP_IMAGE_LATEST}" ]]; then
  N4_NP_VERSION_TEST_ARGS="--e2e.n4-minor-release-image=${OCP_IMAGE_N4}"
fi

MI_ARGS=""
if [[ "${AUTH_THROUGH_CERTS}" == "true" ]]; then
  MI_ARGS="--e2e.azure-managed-identities-file=${AZURE_MANAGED_IDENTITIES_LOCATION}"
fi

DP_ARGS=""
if [[ "${AUTH_THROUGH_CERTS}" == "true" ]]; then
  DP_ARGS="--e2e.azure-data-plane-identities-file=${AZURE_DATA_PLANE_IDENTITIES_LOCATION}"
fi

AZURE_MULTI_ARCH_PARAMS=""
if [[ "${AZURE_MULTI_ARCH:-}" == "true" ]]; then
  AZURE_MULTI_ARCH_PARAMS="--e2e.azure-multi-arch=true"
fi

MARKETPLACE_IMAGE_PARAMS=""
# Use environment variables if set, otherwise use defaults based on version
if [[ -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER:-}" && -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER:-}" && -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU:-}" && -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION:-}" ]]; then
  MARKETPLACE_IMAGE_PARAMS="--e2e.azure-marketplace-publisher ${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER} --e2e.azure-marketplace-offer ${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER} --e2e.azure-marketplace-sku ${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU} --e2e.azure-marketplace-version ${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION}"
fi

OAUTH_EXTERNAL_OIDC_PARAM=""
if [ -f ${SHARED_DIR}/external-oidc-provider ] ; then
    source ${SHARED_DIR}/external-oidc-provider
fi
if [[ "${OAUTH_EXTERNAL_OIDC_PROVIDER}" != "" ]]; then
  case "${OAUTH_EXTERNAL_OIDC_PROVIDER}" in
    "keycloak")
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
    ${N3_NP_VERSION_TEST_ARGS:-} \
    ${N4_NP_VERSION_TEST_ARGS:-} \
    ${MI_ARGS:-} \
    ${DP_ARGS:-} \
    ${AZURE_MULTI_ARCH_PARAMS:-} \
  --e2e.azure-encryption-key-id=${AKS_KMS_KEY} \
  --e2e.azure-kms-credentials-secret-name=${AKS_KMS_CREDENTIALS_SECRET} \
  ${MARKETPLACE_IMAGE_PARAMS} \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  ${OAUTH_EXTERNAL_OIDC_PARAM:-} \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" &
wait $!