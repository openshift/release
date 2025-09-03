#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
AZURE_MANAGED_IDENTITIES_LOCATION="/etc/hypershift-ci-jobs-azurecreds/managed-identities.json"
AZURE_WORKLOAD_IDENTITIES_LOCATION="/etc/hypershift-ci-jobs-azurecreds/dataplane-identities.json"

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

CONTROLPLANE_COMPONENTS=("disk" "file" "imageRegistry" "cloudProvider" "network" "controlPlaneOperator" "ingress" "nodePoolManagement")
DATAPLANE_COMPONENTS=("imageRegistryMSIClientID" "diskMSIClientID" "fileMSIClientID")

# Function to get client ID for a component
get_controlplane_object_id() {
  local component=$1
  local client_id
  client_id=$(jq -r ."$component".clientID < "${AZURE_MANAGED_IDENTITIES_LOCATION}")

  az ad sp show --id "$client_id" | jq -r .id
}

get_dataplane_object_id() {
  local component=$1
  local client_id
  client_id=$(jq -r ."$component" < "${AZURE_WORKLOAD_IDENTITIES_LOCATION}")

  az ad sp show --id "$client_id" | jq -r .id
}

# Assign roles
for component in "${CONTROLPLANE_COMPONENTS[@]}"; do
  object_id=$(get_controlplane_object_id "$component")
  if [[ -z "$object_id" ]]; then
    echo "Error: Missing objectID for component $component" >&2
    exit 1
  fi

  ROLE="b24988ac-6180-42a0-ab88-20f7382dd24c"
  scopes="/subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_HC"

  if [[ $component == "ingress" ]]; then
    ROLE="0336e1d3-7a87-462b-b6db-342b63f7802c"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$BASE_DOMAIN_RESOURCE_GROUP"
  fi

  if [[ $component == "cloudProvider" ]]; then
    ROLE="a1f96423-95ce-4224-ab27-4e3dc72facd4"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "controlPlaneOperator" ]]; then
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "nodePoolManagement" ]]; then
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "disk" ]]; then
    ROLE="5b7237c5-45e1-49d6-bc18-a1f62f400748"
  fi

  if [[ $component == "file" ]]; then
    ROLE="0d7aedc0-15fd-4a67-a412-efad370c947e"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "network" ]]; then
    ROLE="be7a6435-15ae-4171-8f30-4a343eff9e8f"
  fi

  if [[ $component == "imageRegistry" ]]; then
    ROLE="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
  fi

  for scope in $scopes; do
    if [ -z "$(az role assignment list --assignee $object_id --role "$ROLE" --scope $scope -o tsv)" ]; then
      echo "Role assignment does not exist. Creating..."
      az role assignment create --assignee-object-id "$object_id" --role "$ROLE" --scope "$scope" --assignee-principal-type "ServicePrincipal"
    else
      echo "Role assignment already exists. Skipping."
    fi
  done
done

for component in "${DATAPLANE_COMPONENTS[@]}"; do
  object_id=$(get_dataplane_object_id "$component")
  if [[ -z "$object_id" ]]; then
    echo "Error: Missing objectID for component $component" >&2
    exit 1
  fi

  scope="/subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_HC"

  if [[ $component == "imageRegistryMSIClientID" ]]; then
    ROLE="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
  fi

  if [[ $component == "diskMSIClientID" ]]; then
    ROLE="5b7237c5-45e1-49d6-bc18-a1f62f400748"
  fi

  if [[ $component == "fileMSIClientID" ]]; then
    ROLE="0d7aedc0-15fd-4a67-a412-efad370c947e"
  fi

  az role assignment create --assignee-object-id "$object_id" --role "$ROLE" --scope "$scope" --assignee-principal-type "ServicePrincipal"

done