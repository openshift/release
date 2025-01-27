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

  ROLE="Contributor"
  scopes="/subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_HC"

  if [[ $component == "ingress" ]]; then
    ROLE="Azure Red Hat OpenShift Cluster Ingress Operator Role"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$BASE_DOMAIN_RESOURCE_GROUP"
  fi

  if [[ $component == "cloudProvider" ]]; then
    ROLE="Azure Red Hat OpenShift Cloud Controller Manager Role"
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
    ROLE="Azure Red Hat OpenShift Storage Operator Role"
  fi

  if [[ $component == "file" ]]; then
    ROLE="Azure Red Hat OpenShift Azure Files Storage Operator Role"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "network" ]]; then
    ROLE="Azure Red Hat OpenShift Network Operator Role"
  fi

  if [[ $component == "imageRegistry" ]]; then
    ROLE="Azure Red Hat OpenShift Image Registry Operator Role"
  fi

  for scope in $scopes; do
    az role assignment create --assignee-object-id "$object_id" --role "$ROLE" --scope "$scope" --assignee-principal-type "ServicePrincipal"
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
    ROLE="Azure Red Hat OpenShift Image Registry Operator Role"
  fi

  if [[ $component == "diskMSIClientID" ]]; then
    ROLE="Azure Red Hat OpenShift Storage Operator Role"
  fi

  if [[ $component == "fileMSIClientID" ]]; then
    ROLE="Azure Red Hat OpenShift Azure Files Storage Operator Role"
  fi

  az role assignment create --assignee-object-id "$object_id" --role "$ROLE" --scope "$scope" --assignee-principal-type "ServicePrincipal"

done