#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
  AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
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

list_vnet_tags="${SHARED_DIR}/list_azure_existing_vnet_tags.sh"
if [ -f "${list_vnet_tags}" ]; then
    sh -x "${list_vnet_tags}"
fi

remove_resources_by_cli="${SHARED_DIR}/remove_resources_by_cli.sh"
if [ -f "${remove_resources_by_cli}" ]; then
    sh -x "${remove_resources_by_cli}"
fi

rg_files=(
    "${SHARED_DIR}/RESOURCE_GROUP_NAME"
    "${SHARED_DIR}/resourcegroup"
    "${SHARED_DIR}/resourcegroup_cluster"
    "${SHARED_DIR}/resourcegroup_vnet"
    "${SHARED_DIR}/resourcegroup_nsg"
    "${SHARED_DIR}/resourcegroup_aks"
    "${SHARED_DIR}/resourcegroup_sa"
)
for rg_file in "${rg_files[@]}"; do
    if [ -f "${rg_file}" ]; then
        existing_rg=$(cat "${rg_file}")
        if [ "$(az group exists -n "${existing_rg}")" == "true" ]; then
            echo "Removing resource group ${existing_rg} from ${rg_file}"
            az group delete -y -n "${existing_rg}"
        fi
    fi
done

# Remove resource group across subscriptions, and "az account set --subscription <cross subscription>" is used
# Please better to ensure this is kept at the end of the script.
if [ -f ${SHARED_DIR}/resourcegroup_cross-sub ]; then
    # Exit with failure to ensure no leftovers are left unnoticed.  
    if [[ ! -f "${CLUSTER_PROFILE_DIR}/azure-sp-contributor.json" ]]; then
        echo "Error: Expected service principal not found. Cannot remove resources across subscriptions."
        exit 1
    fi
    echo "Setting AZURE credential with Contributor role for removing the resource group from cross subscription"
    AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/azure-sp-contributor.json"
    AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
    AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
    AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
    CROSS_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .crossSubscriptionId)"
    existing_rg=$(cat "${SHARED_DIR}/resourcegroup_cross-sub")
    az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
    az account set --subscription "${CROSS_SUBSCRIPTION_ID}"
    az group delete -y -n "${existing_rg}"
fi