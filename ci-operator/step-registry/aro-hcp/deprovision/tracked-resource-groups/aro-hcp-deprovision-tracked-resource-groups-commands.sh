#!/bin/bash
set -o nounset
set -o pipefail
set -o errexit
set -o xtrace

if [[ -z "${BUILD_ID:-}" || "${BUILD_ID}" =~ ^[[:space:]]*$ ]]; then
    printf 'ERROR: BUILD_ID must be non-blank for resource group cleanup.\n' >&2
    exit 1
fi

# int/stg/prod run a real RP. no-rp mode bypasses it and is only valid when the
# infrastructure has already been cleaned up, so it must never be used there.
case "${VAULT_SECRET_PROFILE}" in
    int*|stg*|prod*)
        if [[ "${CLEANUP_MODE:-}" == "no-rp" ]]; then
            printf 'ERROR: CLEANUP_MODE=no-rp is not allowed for VAULT_SECRET_PROFILE=%s; clean up through the RP.\n' "${VAULT_SECRET_PROFILE}" >&2
            exit 1
        fi
        ;;
esac

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# The cleanup must use the customer subscription and the credentials that own
# it, exactly as the test run did, so require the slot-manager runtime contract
# instead of resolving either from the cluster profile.
env_file="${SHARED_DIR:-}/aro-hcp-slot.env"
if [[ ! -f "${env_file}" ]]; then
  printf 'ERROR: slot-manager runtime contract not found at %s\n' "${env_file}" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${env_file}"
: "${CUSTOMER_SUBSCRIPTION:?slot-manager did not export CUSTOMER_SUBSCRIPTION}"
: "${CUSTOMER_SUBSCRIPTION_ID:?slot-manager did not export CUSTOMER_SUBSCRIPTION_ID}"
: "${SELECTED_CLUSTER_PROFILE_DIR:?slot-manager did not export SELECTED_CLUSTER_PROFILE_DIR}"
# Cross-tenant gating: the exported profile dir owns the leased subscription, so
# cleanup authenticates in the same tenant as the test step.
CLUSTER_PROFILE_DIR="${SELECTED_CLUSTER_PROFILE_DIR}"

# Tracing is disabled while the client-secret is read, otherwise xtrace expands
# it into the publicly readable build log. It is re-enabled after az login.
set +o xtrace
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_TOKEN_CREDENTIALS=prod

export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${CUSTOMER_SUBSCRIPTION_ID}"
set -o xtrace

cmd=(./test/aro-hcp-tests cleanup resource-groups --tracked --shared-dir "${SHARED_DIR}" --job-id "${BUILD_ID}" --timeout "${CLEANUP_TIMEOUT}" --concurrency "${CLEANUP_CONCURRENCY}")

# Service association links are only deleted by the CLI in no-rp mode, which
# needs the first-party app credentials. Standard mode deletes through the RP.
if [[ "${CLEANUP_MODE:-}" == "no-rp" ]]; then
  FPA_CLIENT_ID_FILE="${CLUSTER_PROFILE_DIR}/first-party-app-client-id"
  FPA_CERT_FILE="${CLUSTER_PROFILE_DIR}/fpa-cert2-value"

  if [ -s "${FPA_CLIENT_ID_FILE}" ] && [ -s "${FPA_CERT_FILE}" ]; then
    FPA_CLIENT_ID=$(cat "${FPA_CLIENT_ID_FILE}")

    FPA_CERT_PFX="/tmp/fpa-cert.pfx"
    FPA_CERT_PEM="/tmp/fpa-cert.pem"
    base64 -d "${FPA_CERT_FILE}" > "${FPA_CERT_PFX}"
    openssl pkcs12 -in "${FPA_CERT_PFX}" -out "${FPA_CERT_PEM}" -nodes -passin pass:

    cmd+=(--fpa-client-id "${FPA_CLIENT_ID}" --fpa-cert-path "${FPA_CERT_PEM}")
    echo "FPA credentials found - SAL deletion enabled"
  else
    echo "FPA credentials not found - SAL deletion disabled"
  fi
fi

if [ -n "${CLEANUP_MODE}" ]; then
  cmd+=(--mode "${CLEANUP_MODE}")
fi

"${cmd[@]}"
