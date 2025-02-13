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
if [[ "${CLUSTER_TYPE}" == "azuremag" ]] || [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    echo "The installation with minimal permissions is only supported on Azure Public Cloud, no SP or custom role to be destroyed on ${CLUSTER_TYPE}"
    exit 0
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

azure_role_assignment_file="${SHARED_DIR}/azure_role_assignment_ids"
if [[ -f "${azure_role_assignment_file}" ]]; then
    echo "Deleting role assignment ..."
    while read id; do
        run_command "az role assignment delete --ids ${id}"
    done < "${azure_role_assignment_file}"
fi
