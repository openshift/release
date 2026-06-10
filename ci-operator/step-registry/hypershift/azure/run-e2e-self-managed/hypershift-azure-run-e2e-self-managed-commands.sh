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

check_e2e_flag() {
  grep -q "$1" <<<"$( bin/test-e2e -h 2>&1 )"
  return $?
}

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

ZONES_ARGS=""
if [[ "${HYPERSHIFT_AZURE_ZONES:-}" != "" ]]; then
  ZONES_ARGS="--e2e.availability-zones=${HYPERSHIFT_AZURE_ZONES}"
fi

ETCD_STORAGE_CLASS_ARGS=""
if [[ "${HYPERSHIFT_ETCD_STORAGE_CLASS:-}" != "" ]]; then
  ETCD_STORAGE_CLASS_ARGS="--e2e.etcd-storage-class=${HYPERSHIFT_ETCD_STORAGE_CLASS}"
fi

# Azure private platform args - pass credentials and resource group to the e2e test framework
# so the HO upgrade test can reinstall with private platform support.
# Values can come from env vars or from SHARED_DIR files written by the
# hypershift-azure-setup-private-link step.
# The AZURE_PRIVATE_NAT_SUBNET_ID env var is read directly by TestAzurePrivateTopology;
# when empty, the test self-skips.
PLS_RG="${AZURE_PLS_RESOURCE_GROUP:-}"
if [[ -z "${PLS_RG}" && -f "${SHARED_DIR}/azure_pls_resource_group" ]]; then
  PLS_RG="$(cat "${SHARED_DIR}/azure_pls_resource_group")"
fi
NAT_SUBNET="${AZURE_PRIVATE_NAT_SUBNET_ID:-}"
if [[ -z "${NAT_SUBNET}" && -f "${SHARED_DIR}/azure_private_nat_subnet_id" ]]; then
  NAT_SUBNET="$(cat "${SHARED_DIR}/azure_private_nat_subnet_id")"
fi
PRIVATE_CREDS="${AZURE_PRIVATE_CREDS_FILE:-}"
if [[ -z "${PRIVATE_CREDS}" && -f "${SHARED_DIR}/azure_private_link_creds_file" ]]; then
  PRIVATE_CREDS="$(cat "${SHARED_DIR}/azure_private_link_creds_file")"
fi
AZURE_PRIVATE_ARGS=""
if [[ -n "${PRIVATE_CREDS}" && -n "${PLS_RG}" ]]; then
  AZURE_PRIVATE_ARGS="--e2e.private-platform=Azure \
    --e2e.azure-private-credentials-file=${PRIVATE_CREDS} \
    --e2e.azure-pls-resource-group=${PLS_RG}"
fi
export AZURE_PRIVATE_NAT_SUBNET_ID="${NAT_SUBNET}"

ADDITIONAL_PULL_SECRET_PARAMS=""
if check_e2e_flag 'e2e.additional-pull-secret-file' && [[ -f /etc/hypershift-additional-pull-secret/.dockerconfigjson ]]; then
  ADDITIONAL_PULL_SECRET_PARAMS="--e2e.additional-pull-secret-file=/etc/hypershift-additional-pull-secret/.dockerconfigjson"
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
    ${ZONES_ARGS:-} \
    ${ETCD_STORAGE_CLASS_ARGS:-} \
    ${AZURE_PRIVATE_ARGS:-} \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" \
  ${ADDITIONAL_PULL_SECRET_PARAMS:-} &
wait $!
