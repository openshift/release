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

OUTBOUND_PORTS=${OUTBOUND_PORTS:="64"}
OUTBOUND_RULE_NAME=${OutboundNATAllProtocols:="OutboundNATAllProtocols"}

getResourceGroup

LOAD_BALACER="$(az network lb list -g $RESOURCE_GROUP | jq -r '.[].name' | grep -v internal)"

echo "Check outbound port"
az network lb outbound-rule list -g $RESOURCE_GROUP -o table --lb-name $LOAD_BALACER
echo "Updating outbound port"
az network lb outbound-rule update -g $RESOURCE_GROUP --lb $LOAD_BALACER --outbound-ports $OUTBOUND_PORTS --name $OUTBOUND_RULE_NAME
echo "Check outbound port after update"
az network lb outbound-rule list -g $RESOURCE_GROUP -o table --lb-name $LOAD_BALACER