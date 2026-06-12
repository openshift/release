#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION="${CUSTOMER_SUBSCRIPTION:-$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")}"
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
echo "Using subscription name='${CUSTOMER_SUBSCRIPTION}'"

cmd="./test/aro-hcp-tests cleanup resource-groups --expired"

# Add FPA credentials if available (needed for SAL deletion in no-rp mode)
FPA_CLIENT_ID_FILE="${CLUSTER_PROFILE_DIR}/fpa-cert2-id"
FPA_CERT_FILE="${CLUSTER_PROFILE_DIR}/fpa-cert2-value"

if [ -s "${FPA_CLIENT_ID_FILE}" ] && [ -s "${FPA_CERT_FILE}" ]; then
  FPA_CLIENT_ID=$(cat "${FPA_CLIENT_ID_FILE}")
  cmd="${cmd} --fpa-client-id ${FPA_CLIENT_ID} --fpa-cert-path ${FPA_CERT_FILE}"
  echo "FPA credentials found - SAL deletion enabled"
else
  echo "FPA credentials not found - SAL deletion disabled"
fi

if [ -n "${CLEANUP_MODE}" ]; then
  cmd="${cmd} --mode ${CLEANUP_MODE}"
fi

if [ -n "${INCLUDE_LOCATION}" ]; then
  cmd="${cmd} --include-location ${INCLUDE_LOCATION}"
fi

if [ -n "${EXCLUDE_LOCATION}" ]; then
  cmd="${cmd} --exclude-location ${EXCLUDE_LOCATION}"
fi

eval "${cmd}"
