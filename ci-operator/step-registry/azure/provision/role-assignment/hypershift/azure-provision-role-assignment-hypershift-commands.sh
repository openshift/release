#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
AZURE_MANAGED_IDENTITIES_LOCATION="/etc/hypershift-ci-jobs-azurecreds/managed-identities.json"

# Load Azure credentials
AZURE_AUTH_CLIENT_ID="$(jq -r .clientId < "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_CLIENT_SECRET="$(jq -r .clientSecret < "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_SUBSCRIPTION_ID="$(jq -r .subscriptionId < "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_TENANT_ID="$(jq -r .tenantId < "${AZURE_AUTH_LOCATION}")"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

RG_NSG=$(<"${SHARED_DIR}/resourcegroup_nsg")
RG_VNET=$(<"${SHARED_DIR}/resourcegroup_vnet")
RG_HC=$(<"${SHARED_DIR}/resourcegroup")

COMPONENTS=("disk" "file" "imageRegistry" "cloudProvider" "network" "controlPlaneOperator" "ingress" "nodePoolManagement")

# Function to get client ID for a component
get_client_id() {
  local component=$1
  jq -r ."$component".clientID < "${AZURE_MANAGED_IDENTITIES_LOCATION}"
}

# Assign roles
for component in "${COMPONENTS[@]}"; do
  client_id=$(get_client_id "$component")
  if [[ -z "$client_id" ]]; then
    echo "Error: Missing clientID for component $component" >&2
    exit 1
  fi

  scopes="/subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_HC"

  if [[ $component == "ingress" ]]; then
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$BASE_DOMAIN_RESOURCE_GROUP"
  fi

  if [[ $component == "cloudProvider" ]]; then
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
  fi

  if [[ $component == "controlPlaneOperator" ]]; then
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "nodePoolManagement" ]]; then
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  object_id=$(az ad sp show --id "$client_id" | jq -r .id)

  for scope in $scopes; do
    az role assignment create --assignee-object-id "$object_id" --role "Contributor" --scope "$scope" --assignee-principal-type "ServicePrincipal"
  done
done