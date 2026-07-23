#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    # Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
    chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
    source ${SHARED_DIR}/azurestack-login-script.sh
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}


function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# destroy cluster resource group created by installer
infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
cluster_rg_from_installer="${infra_id}-rg"
run_command "az group show -n ${cluster_rg_from_installer}"
run_command "az group delete -y -n ${cluster_rg_from_installer}"

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
cluster_publish=$(yq-go r "${INSTALL_CONFIG}" 'publish')
if [[ "${cluster_publish}" == "Internal" ]]; then
    echo "This is a private cluster, skip to check public dns records."
    exit 0
fi

base_domain=$(yq-go r "${INSTALL_CONFIG}" 'baseDomain')
base_domain_rg=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.baseDomainResourceGroupName')
cluster_name=$(jq -r '.clusterName' ${SHARED_DIR}/metadata.json)
run_command "az network dns record-set list -g ${base_domain_rg} -z ${base_domain} --query \"[?contains(name, '$cluster_name')]\" -o json"
