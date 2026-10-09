#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

slot_env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ ! -f "${slot_env_file}" ]]; then
    echo "ERROR: slot-manager runtime contract not found at ${slot_env_file}"
    exit 1
fi
# shellcheck disable=SC1090
source "${slot_env_file}"
: "${CUSTOMER_SUBSCRIPTION_ID:?slot-manager did not export CUSTOMER_SUBSCRIPTION_ID}"

start_time_fallback_args=()
if [[ -f "${SHARED_DIR}/write-config-timestamp-rfc3339" ]]; then
  start_time_fallback_args=(
    --start-time-fallback
    "$(cat "${SHARED_DIR}/write-config-timestamp-rfc3339")"
  )
fi

test/aro-hcp-tests custom-link-tools \
  --timing-input "${SHARED_DIR}" \
  --output "${ARTIFACT_DIR}/" \
  --rendered-config "${SHARED_DIR}/config.yaml" \
  --subscription-id "${CUSTOMER_SUBSCRIPTION_ID}" \
  "${start_time_fallback_args[@]}"
