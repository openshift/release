#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Cross-tenant gating: when slot-manager acquire leased the subscription it
# records the cluster profile dir that owns it (its tenant + service principal)
# as SELECTED_CLUSTER_PROFILE_DIR. Honor it so generated links target the leased
# subscription rather than the fallback VAULT_SECRET_PROFILE dir, which may point
# at a different tenant in the mixed-tenant model. Mirrors aro-hcp-test-persistent.
slot_env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${slot_env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${slot_env_file}"
    if [[ -n "${SELECTED_CLUSTER_PROFILE_DIR:-}" ]]; then
        CLUSTER_PROFILE_DIR="${SELECTED_CLUSTER_PROFILE_DIR}"
    fi
fi

export AZURE_TOKEN_CREDENTIALS=prod
SUB_FILE="${CLUSTER_PROFILE_DIR}/subscription-id"
if [[ ! -s "${SUB_FILE}" ]]; then
  echo "No subscription-id file found at ${SUB_FILE}"
  exit 1
fi
SUBSCRIPTION_ID=$(cat "${SUB_FILE}")

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
