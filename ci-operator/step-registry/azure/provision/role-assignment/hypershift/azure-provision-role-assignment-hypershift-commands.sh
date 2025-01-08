#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

SP_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
KV_NAME=$(<"${SHARED_DIR}/azure_keyvault_name")
RG_NSG=$(<"${SHARED_DIR}/resourcegroup_nsg")
RG_VNET=$(<"${SHARED_DIR}/resourcegroup_vnet")
RG_HC=$(<"${SHARED_DIR}/resourcegroup")
COMPONENTS="disk file imageRegistry cloudProvider network controlPlaneOperator ingress nodePoolManagement"

declare -A component_to_client_id

component_to_client_id["cloudProvider"]="$(<"${AZURE_MANAGED_IDENTITES_LOCATION}" jq -r .cloudProvider.clientId)"
component_to_client_id["controlPlaneOperator"]="$(<"${AZURE_MANAGED_IDENTITES_LOCATION}" jq -r .controlPlaneOperator.clientId)"
component_to_client_id["disk"]="$(<"${AZURE_MANAGED_IDENTITES_LOCATION}" jq -r .disk.clientId)"
component_to_client_id["file"]="$(<"${AZURE_MANAGED_IDENTITES_LOCATION}" jq -r .file.clientId)"
component_to_client_id["imageRegistry"]="$(<"${AZURE_MANAGED_IDENTITES_LOCATION}" jq -r .imageRegistry.clientId)"
component_to_client_id["network"]="$(<"${AZURE_MANAGED_IDENTITES_LOCATION}" jq -r .network.clientId)"
component_to_client_id["ingress"]="$(<"${AZURE_MANAGED_IDENTITES_LOCATION}" jq -r .ingress.clientId)"
component_to_client_id["nodePoolManagement"]="$(<"${AZURE_MANAGED_IDENTITES_LOCATION}" jq -r .nodePoolManagement.clientId)"

for component in $COMPONENTS; do
    scopes="/subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_HC"
    if [[ $component == "ingress" ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$BASE_DOMAIN_RESOURCE_GROUP"
    elif [[ $component == "cloudProvider" ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    elif [[ $component == "controlPlaneOperator" ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    elif [[ $component == "nodePoolManagement" ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    fi

    for scope in $scopes; do
      az role assignment create --assignee-object-id "${component_to_client_id[$component]}" --role "Contributor" --scope "$scope" --assignee-principal-type "ServicePrincipal"
    done
done