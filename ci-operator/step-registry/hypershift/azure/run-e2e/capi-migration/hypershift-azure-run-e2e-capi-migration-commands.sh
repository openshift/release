#!/bin/bash

set +x

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

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

check_e2e_flag() {
  grep -Fq -- "$1" <<<"$( bin/test-e2e -h 2>&1 )"
  return $?
}

CAPI_MIGRATION_PARAM=""
if check_e2e_flag "capi-migration.run-tests" ; then
  CAPI_MIGRATION_PARAM="--capi-migration.run-tests"
fi

EXTERNAL_DNS_ARGS=""
if [[ "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN:-}" != "" ]]; then
  EXTERNAL_DNS_ARGS="--e2e.external-dns-domain=${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"
fi

AKS_ANNOTATIONS=""
HC_ANNOTATIONS_FILE="${SHARED_DIR}/hypershift_hc_annotations"
if [[ -f "$HC_ANNOTATIONS_FILE" ]]; then
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      AKS_ANNOTATIONS+=" --e2e.annotations=${line}"
    fi
  done < "$HC_ANNOTATIONS_FILE"
fi

MI_ARGS=""
if [[ "${AUTH_THROUGH_CERTS}" == "true" ]]; then
  MI_ARGS="--e2e.azure-managed-identities-file=/etc/hypershift-ci-jobs-azurecreds/managed-identities.json"
fi

DP_ARGS=""
if [[ "${AUTH_THROUGH_CERTS}" == "true" ]]; then
  DP_ARGS="--e2e.azure-data-plane-identities-file=/etc/hypershift-ci-jobs-azurecreds/dataplane-identities.json"
fi

MARKETPLACE_IMAGE_PARAMS=""
if [[ -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER:-}" && -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER:-}" && -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU:-}" && -n "${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION:-}" ]]; then
  MARKETPLACE_IMAGE_PARAMS="--e2e.azure-marketplace-publisher ${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER} --e2e.azure-marketplace-offer ${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER} --e2e.azure-marketplace-sku ${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_SKU} --e2e.azure-marketplace-version ${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_VERSION}"
fi

ADDITIONAL_PULL_SECRET_PARAMS=""
if check_e2e_flag 'e2e.additional-pull-secret-file' && [[ -f /etc/hypershift-additional-pull-secret/.dockerconfigjson ]]; then
  ADDITIONAL_PULL_SECRET_PARAMS="--e2e.additional-pull-secret-file=/etc/hypershift-additional-pull-secret/.dockerconfigjson"
fi

hack/ci-test-e2e.sh -test.v \
  -test.run='^TestCAPIStorageVersionMigration$' \
  -test.parallel=1 \
  --e2e.platform=Azure \
  --e2e.azure-credentials-file=/etc/hypershift-ci-jobs-azurecreds/credentials.json \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.base-domain=hypershift.azure.devcluster.openshift.com \
  --e2e.azure-location=${HYPERSHIFT_AZURE_LOCATION} \
  --e2e.oidc-issuer-url=${AZURE_OIDC_ISSUER_URL} \
  --e2e.sa-token-issuer-private-key-path=${AZURE_SA_TOKEN_ISSUER_KEY_PATH} \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" \
  --e2e.azure-encryption-key-id=${AKS_KMS_KEY} \
  --e2e.azure-kms-credentials-secret-name=${AKS_KMS_CREDENTIALS_SECRET} \
  --e2e.ho-enable-ci-debug-output=true \
  --e2e.hypershift-operator-latest-image=${CI_HYPERSHIFT_OPERATOR} \
  ${EXTERNAL_DNS_ARGS:-} \
  ${AKS_ANNOTATIONS:-} \
  ${MI_ARGS:-} \
  ${DP_ARGS:-} \
  ${MARKETPLACE_IMAGE_PARAMS} \
  ${CAPI_MIGRATION_PARAM} \
  ${ADDITIONAL_PULL_SECRET_PARAMS:-} &
wait $!
