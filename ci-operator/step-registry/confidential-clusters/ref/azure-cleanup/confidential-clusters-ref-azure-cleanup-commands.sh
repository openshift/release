#!/bin/bash
set -euo pipefail

RESOURCE_GROUP_FILE="${SHARED_DIR}/cocl-resourcegroup"
if [[ ! -f "${RESOURCE_GROUP_FILE}" ]]; then
  echo "No resource group was recorded, nothing to clean up"
  exit 0
fi
RESOURCE_GROUP=$(cat "${RESOURCE_GROUP_FILE}")

CLIENT_ID=$(jq -r .clientId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
CLIENT_SECRET=$(jq -r .clientSecret "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
TENANT_ID=$(jq -r .tenantId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
SUBSCRIPTION_ID=$(jq -r .subscriptionId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
az login --service-principal \
  -u "${CLIENT_ID}" \
  -p "${CLIENT_SECRET}" \
  --tenant "${TENANT_ID}" \
  --output none
az account set --subscription "${SUBSCRIPTION_ID}"

if az group show --name "${RESOURCE_GROUP}" --output none 2>/dev/null; then
  echo "Deleting resource group ${RESOURCE_GROUP}"
  az group delete --name "${RESOURCE_GROUP}" --yes
else
  echo "Resource group ${RESOURCE_GROUP} does not exist, nothing to clean up"
fi
