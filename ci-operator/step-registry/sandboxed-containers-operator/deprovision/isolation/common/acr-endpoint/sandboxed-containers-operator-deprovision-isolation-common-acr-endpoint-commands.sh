#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -s "${SHARED_DIR}/resourcegroup" ]]; then
    echo "No ${SHARED_DIR}/resourcegroup, nothing to clean up"
    exit 0
fi
CLUSTER_RG=$(<"${SHARED_DIR}/resourcegroup")

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

ACR_RG="${ACR_RESOURCE_GROUP:-osc-ci-mirror-rg}"
ACR_NAME="${ACR_NAME:-osccimirror}"

# The connection on the ACR side points to the private endpoint created in
# this run's cluster resource group. Azure may report the resource group in
# a different case, so match it case-insensitively.
connection=$(az acr private-endpoint-connection list \
    --registry-name "${ACR_NAME}" --resource-group "${ACR_RG}" \
    --query "[].[name, privateEndpoint.id]" -o tsv | \
    grep -i "/resourceGroups/${CLUSTER_RG}/" | cut -f1 || true)

if [[ -z "${connection}" ]]; then
    echo "No private endpoint connection on ${ACR_NAME} for ${CLUSTER_RG}"
    exit 0
fi

echo "Deleting private endpoint connection ${connection} from ${ACR_NAME}"
az acr private-endpoint-connection delete \
    --registry-name "${ACR_NAME}" --resource-group "${ACR_RG}" \
    --name "${connection}"
