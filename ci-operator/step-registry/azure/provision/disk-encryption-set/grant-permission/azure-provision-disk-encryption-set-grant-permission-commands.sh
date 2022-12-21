#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none


echo "Grants the cluster service principal Contributor privileges to the disk encryption set"
des_name=$(cat "${SHARED_DIR}/azure_des")
RESOURCE_GROUP=$(cat "${SHARED_DIR}/resourcegroup")
des_id=$(az disk-encryption-set show -n ${des_name} -g ${RESOURCE_GROUP} --query "[id]" -o tsv)
infra_id=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
principal_id=$(az identity show -g "${infra_id}-rg" -n "${infra_id}-identity" --query principalId --out tsv)
run_command "az role assignment create --assignee ${principal_id} --role 'Contributor' --scope ${des_id}"
