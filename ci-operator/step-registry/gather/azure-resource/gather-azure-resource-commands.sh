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
        AZURESTACK_ENDPOINT=$(cat ${SHARED_DIR}/AZURESTACK_ENDPOINT)
        SUFFIX_ENDPOINT=$(cat ${SHARED_DIR}/SUFFIX_ENDPOINT)
        cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")
        if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
            cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
            cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
            export REQUESTS_CA_BUNDLE=/tmp/ca.pem
        fi
        az cloud register \
            -n ${cloud_name} \
            --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
            --suffix-storage-endpoint "${SUFFIX_ENDPOINT}" 
        az cloud set -n ${cloud_name}
        az cloud update --profile 2019-03-01-hybrid
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
            if [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
                run_command "az network lb address-pool show --lb-name $lb --name $ap --resource-group $RESOURCE_GROUP | jq -r .backendIPConfigurations[].id"
            else
                run_command "az network lb address-pool address list --lb-name $lb --pool-name $ap --resource-group $RESOURCE_GROUP -o table"
            fi
        done
    done    
}

function getResourceGroup() {
    local CONFIG 
    CONFIG="${SHARED_DIR}/install-config.yaml"
    RESOURCE_GROUP=$(yq-go r "${CONFIG}" 'platform.azure.resourceGroupName')
    echo "resourceGroupName in $CONFIG: $RESOURCE_GROUP"
    if [[ -z "${RESOURCE_GROUP}" ]]; then
        RESOURCE_GROUP="$(jq -r .infraID ${SHARED_DIR}/metadata.json)-rg"
    fi
    export RESOURCE_GROUP
}

cli_Login

OUTPUT_DIR="${ARTIFACT_DIR}"

getResourceGroup
run_command "az group show --name $RESOURCE_GROUP"

run_command "az vm list --resource-group $RESOURCE_GROUP -o tsv"

run_command "az resource list --resource-group $RESOURCE_GROUP -o tsv"

gatherLBs
