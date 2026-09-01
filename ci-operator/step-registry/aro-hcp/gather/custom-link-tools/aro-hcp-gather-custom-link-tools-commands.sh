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
if [[ -s "${SUB_FILE}" ]]; then
  SUBSCRIPTION_ID=$(cat "${SUB_FILE}")
else
  # Some cross-tenant cluster profiles (e.g. the -rh prod profiles) don't have
  # a pre-populated subscription-id secret. Fall back to resolving it by
  # subscription name via az, authenticating the same way aro-hcp-test-persistent
  # already does with this profile's client-id/tenant/client-secret.
  echo "No subscription-id file found at ${SUB_FILE}, falling back to resolving it via subscription name"
  NAME_FILE="${CLUSTER_PROFILE_DIR}/subscription-name"
  if [[ ! -s "${NAME_FILE}" ]]; then
    echo "No subscription-name file found at ${NAME_FILE} either, cannot resolve subscription ID"
    exit 1
  fi

  # Disable tracing before the subscription name (and the service-principal
  # credentials) are read, and keep it disabled through the az calls and
  # error handling below so neither value is ever echoed into CI logs.
  set +o xtrace
  SUBSCRIPTION_NAME=$(cat "${NAME_FILE}")
  AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
  AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
  AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
  az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
  SUBSCRIPTION_ID=$(az account show --subscription "${SUBSCRIPTION_NAME}" --query id -o tsv)
  set -o xtrace

  if [[ -z "${SUBSCRIPTION_ID}" ]]; then
    echo "Failed to resolve subscription ID for the configured subscription name"
    exit 1
  fi
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
