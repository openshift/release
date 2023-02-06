#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function cli_Login() {
    # set the parameters we'll need as env vars
    AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
    AZURE_AUTH_CLIENT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientId)"
    AZURE_AUTH_CLIENT_SECRET="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientSecret)"
    AZURE_AUTH_TENANT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .tenantId)"

    # az should already be there
    command -v az
    az version

    # log in with az
    if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
        run_command "az cloud set --name AzureUSGovernment" || return 1
    elif [[ "${CLUSTER_TYPE}" == "azure4" ]]; then
        run_command "az cloud set --name AzureCloud" || return 1
    elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
        echo "Unsupported cluster: ${CLUSTER_TYPE}"
        exit 1
    else
        echo "Unexpected cluster: ${CLUSTER_TYPE}"
        exit 1
    fi
    echo "$(date -u --rfc-3339=seconds) - Logging in to Azure..."
    az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none || return 1
}

function gatherLBs() {
    local lbs aps
    run_command "az network lb list --resource-group $RESOURCE_GROUP > $OUTPUT_DIR/lbs.json"
    run_command "az network lb list --resource-group $RESOURCE_GROUP -o tsv"
    lbs="$(az network lb list -g $RESOURCE_GROUP | jq -r '.[].name')"
    for lb in $lbs; do
        echo "loadbalance: $lb"
        aps="$(az network lb address-pool list -g $RESOURCE_GROUP --lb-name ${lb} | jq -r '.[].name')"
        for ap in $aps; do
            echo "address-pool: $ap"
            run_command "az network lb address-pool address list --lb-name $lb --pool-name $ap --resource-group $RESOURCE_GROUP -o table"
        done
    done    
}

cli_Login

OUTPUT_DIR="${ARTIFACT_DIR}"

RESOURCE_GROUP="$(jq -r .infraID ${SHARED_DIR}/metadata.json)-rg"
run_command "az group show --name $RESOURCE_GROUP"

run_command "az vm list --resource-group $RESOURCE_GROUP -o tsv"

run_command "az resource list --resource-group $RESOURCE_GROUP -o tsv"

gatherLBs