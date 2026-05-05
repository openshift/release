#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_TOKEN_CREDENTIALS=prod
INFRA_SUB_FILE="${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id"
FALLBACK_SUB_FILE="${CLUSTER_PROFILE_DIR}/subscription-id"
if [[ -s "${INFRA_SUB_FILE}" ]]; then
  SUBSCRIPTION_ID=$(cat "${INFRA_SUB_FILE}")
elif [[ -s "${FALLBACK_SUB_FILE}" ]]; then
  SUBSCRIPTION_ID=$(cat "${FALLBACK_SUB_FILE}")
else
  echo "No subscription-id file found in ${CLUSTER_PROFILE_DIR}"
  exit 1
fi

START_TIME_FALLBACK_ARGS=""
if [[ -f "${SHARED_DIR}/write-config-timestamp-rfc3339" ]]; then
  START_TIME_FALLBACK_ARGS="--start-time-fallback $(cat "${SHARED_DIR}/write-config-timestamp-rfc3339")"
fi

test/aro-hcp-tests custom-link-tools \
  --timing-input "${SHARED_DIR}" \
  --output "${ARTIFACT_DIR}/" \
  --rendered-config "${SHARED_DIR}/config.yaml" \
  --subscription-id "${SUBSCRIPTION_ID}" \
  ${START_TIME_FALLBACK_ARGS}
