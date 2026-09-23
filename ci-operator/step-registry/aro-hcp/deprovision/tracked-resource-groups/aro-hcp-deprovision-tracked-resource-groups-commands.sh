#!/bin/bash
set -o nounset
set -o pipefail
set -o errexit
set -o xtrace

if ! compgen -G "${SHARED_DIR}/tracked-resource-group_*" > /dev/null; then
    printf 'No tracked resource group files found, nothing to clean up.\n'
    exit 0
fi

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Require the slot-manager runtime contract so cleanup uses the same customer
# subscription and owning credentials as the test run.
env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ ! -f "${env_file}" ]]; then
  echo "ERROR: slot-manager runtime contract not found at ${env_file}"
  exit 1
fi
# shellcheck disable=SC1090
source "${env_file}"
: "${CUSTOMER_SUBSCRIPTION:?slot-manager did not export CUSTOMER_SUBSCRIPTION}"
: "${CUSTOMER_SUBSCRIPTION_ID:?slot-manager did not export CUSTOMER_SUBSCRIPTION_ID}"
: "${SELECTED_CLUSTER_PROFILE_DIR:?slot-manager did not export SELECTED_CLUSTER_PROFILE_DIR}"
CLUSTER_PROFILE_DIR="${SELECTED_CLUSTER_PROFILE_DIR}"

# Tracing is disabled while the client-secret is read, otherwise xtrace expands
# it into the publicly readable build log. It is re-enabled after az login.
set +o xtrace
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${CUSTOMER_SUBSCRIPTION_ID}"
set -o xtrace

cmd=(./test/aro-hcp-tests cleanup resource-groups --tracked --shared-dir "${SHARED_DIR}")

# Add FPA credentials if available (needed for SAL deletion in no-rp mode)
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

if [ -n "${CLEANUP_MODE}" ]; then
  cmd+=(--mode "${CLEANUP_MODE}")
fi

"${cmd[@]}"
