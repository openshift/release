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

echo "DEBUG: VAULT_SECRET_PROFILE=${VAULT_SECRET_PROFILE}"
echo "DEBUG: CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR}"
echo "DEBUG: AZURE_CLIENT_ID=${AZURE_CLIENT_ID}"
echo "DEBUG: AZURE_TENANT_ID=${AZURE_TENANT_ID}"

echo "DEBUG: Azure account context:"
az account show \
  --query "{user:user.name, tenantId:tenantId, subscriptionId:id, subscriptionName:name}" \
  -o table

echo "DEBUG: Checking Key Vault access to aro-hcp-dev-svc-kv/firstPartyCert2"
if az keyvault secret show \
  --vault-name aro-hcp-dev-svc-kv \
  --name firstPartyCert2 \
  --query id \
  -o tsv; then
  echo "DEBUG: SUCCESS: Prow identity can access aro-hcp-dev-svc-kv/firstPartyCert2"
else
  echo "DEBUG: FAILURE: Prow identity cannot access aro-hcp-dev-svc-kv/firstPartyCert2"
fi

echo "DEBUG: stopping before cleanup for rehearsal"
exit 0

cmd="./test/aro-hcp-tests cleanup resource-groups --expired"

if [ -n "${CLEANUP_MODE}" ]; then
  cmd="${cmd} --mode ${CLEANUP_MODE}"
fi

if [ -n "${INCLUDE_LOCATION}" ]; then
  cmd="${cmd} --include-location ${INCLUDE_LOCATION}"
fi

if [ -n "${EXCLUDE_LOCATION}" ]; then
  cmd="${cmd} --exclude-location ${EXCLUDE_LOCATION}"
fi

echo "Running: ${cmd}"
eval "${cmd}"
