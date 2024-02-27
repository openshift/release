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

RESOURCE_GROUP=$(cat "${SHARED_DIR}/resourcegroup")
infra_id=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
azure_des_file="${SHARED_DIR}/azure_des.json"
if [[ ! -f "${azure_des_file}" ]]; then
    echo "Unable to find azure_des.json file under SHARED_DIR! Exit..."
    exit 1
fi

#using system role "Contributor" as default permissions
#if customer role is not defined
role_name="Contributor"
if [[ "${ENABLE_MIN_PERMISSION_FOR_DES}" == "true" ]]; then
    role_name=$(< "${SHARED_DIR}/azure_custom_role_name")
fi

echo "Grants the cluster service principal ${role_name} privileges to the disk encryption set"
des_type_list="$(cat ${azure_des_file} | jq -r 'keys[]')"
for type in ${des_type_list}; do
    des_name=$(cat "${azure_des_file}" | jq -r ".${type}")
    echo "processing on ${des_name}"
    des_id=$(az disk-encryption-set show -n "${des_name}" -g "${RESOURCE_GROUP}" --query "[id]" -o tsv)
    principal_id=$(az identity show -g "${infra_id}-rg" -n "${infra_id}-identity" --query principalId --out tsv)
    run_command "az role assignment create --assignee ${principal_id} --role '${role_name}' --scope ${des_id}"
done
