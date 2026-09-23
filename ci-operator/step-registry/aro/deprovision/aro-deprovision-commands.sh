#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

RESOURCEGROUP=${RESOURCEGROUP:=$(cat "${SHARED_DIR}/resourcegroup")}
CLUSTER=${CLUSTER:=$(cat "${SHARED_DIR}/cluster-name")}
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"


echo "logging into Azure cloud"
# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
echo "Deleting ARO cluster ${CLUSTER}"

az aro delete --yes --name="${CLUSTER}" --resource-group="${RESOURCEGROUP}"
az group delete --yes --name="${RESOURCEGROUP}"