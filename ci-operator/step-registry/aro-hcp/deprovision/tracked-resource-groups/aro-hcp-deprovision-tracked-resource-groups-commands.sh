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

# Resolve the slot env first: it may select a different cluster profile dir.
env_file="${SHARED_DIR:-}/aro-hcp-slot.env"
if [[ -f "${env_file}" ]]; then
  # shellcheck disable=SC1090
  source "${env_file}"
fi
# Cross-tenant gating: slot-manager acquire exports the profile dir that owns
# the leased subscription. Use it so cleanup authenticates in the same tenant
# as the test step.
if [[ -n "${SELECTED_CLUSTER_PROFILE_DIR:-}" ]]; then
  CLUSTER_PROFILE_DIR="${SELECTED_CLUSTER_PROFILE_DIR}"
fi

# Tracing is disabled while the client-secret is read, otherwise xtrace expands
# it into the publicly readable build log. It is re-enabled after az login.
set +o xtrace
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_TOKEN_CREDENTIALS=prod

export CUSTOMER_SUBSCRIPTION="${CUSTOMER_SUBSCRIPTION:-$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")}"
export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
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
