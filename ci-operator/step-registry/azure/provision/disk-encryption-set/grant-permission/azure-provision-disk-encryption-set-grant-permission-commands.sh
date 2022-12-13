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

if [ ! -f "${SHARED_DIR}/azure_des" ]; then
    echo "File azure_des does not exist in SHARED_DIR, unable to get disk encrption set name!"
    exit 1
fi

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

RESOURCE_GROUP=$(< "${SHARED_DIR}/resourcegroup")
run_command "az group show --name $RESOURCE_GROUP"; ret=$?
if [ X"$ret" != X"0" ]; then
    echo "The $RESOURCE_GROUP resrouce group does not exist"
    exit 1
fi

#Get disk encrpytion set id
des="$(< "${SHARED_DIR}/azure_des")"
des_id=$(az disk-encryption-set show -n ${des} -g ${RESOURCE_GROUP} --query "[id]" -o tsv)

#Get infra_id
infra_id=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)

#Get cluster identity id
principal_id=$(az identity show -g ${infra_id}-rg -n ${infra_id}-identity --query principalId --out tsv)

echo "Granting clsuter identity Contributor permission to disk encryption set: ${des}"
run_command "az role assignment create --assignee ${principal_id} --role 'Contributor' --scope ${des_id}"
