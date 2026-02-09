#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Load resource group names from provision.env
if [[ -f "${SHARED_DIR}/provision.env" ]]; then
  source "${SHARED_DIR}/provision.env"
else
  echo "ERROR: provision.env not found at ${SHARED_DIR}/provision.env"
  exit 1
fi

# Verify required variables are set and not empty (because nounset)
echo "SVC_RESOURCEGROUP: ${SVC_RESOURCEGROUP}"
echo "MGMT_RESOURCEGROUP: ${MGMT_RESOURCEGROUP}"
echo "REGIONAL_RESOURCEGROUP: ${REGIONAL_RESOURCEGROUP}"

# Check if provisioning completed successfully
if [[ -f "${SHARED_DIR}/provision-complete" ]]; then
  echo "Provisioning completed successfully, skipping failure data gathering"
  exit 0
fi

export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-subscription-id")

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${SUBSCRIPTION_ID}"

# Any data is useful even if something goes wrong
set +o errexit

# List all prow resource groups
echo "All hcp-underlay-prow- RGs:"
az group list --output table \
  --query "sort_by([?starts_with(name, 'hcp-underlay-prow-')].{Name:name, Location:location, Status:properties.provisioningState, CreatedTime:tags.createdAt}, &Name)"

# For each identified resource group, dump detailed information
echo "Resource Group Details and Deployment Status:"
for rg in "${SVC_RESOURCEGROUP}" "${MGMT_RESOURCEGROUP}" "${REGIONAL_RESOURCEGROUP}"; do
  if [[ -z "$rg" ]]; then
    continue
  fi

  # Check if resource group exists
  if ! az group show --name "$rg" --output table 2>&1; then
    echo "Resource group '$rg' does not exist or cannot be accessed"
    continue
  fi

  # List failed resources in the group
  echo -e "\nFailed resources in $rg:"
  az resource list --resource-group "$rg" --output table --query "[?provisioningState!='Succeeded']"

  # List all deployments
  echo -e "\nAll Deployments in $rg:"
  az deployment group list --resource-group "$rg" --output table \
    --query "reverse(sort_by([].{Name:name, State:properties.provisioningState, Timestamp:properties.timestamp}, &Timestamp))"

  # Show detailed failure information for any deployment that's not a success
  echo -e "\nFailed Deployment Details in $rg:"
  FAILED_DEPLOYMENTS=$(az deployment group list --resource-group "$rg" \
    --query "[?properties.provisioningState!='Succeeded'].name" -o tsv 2>/dev/null || echo "")

  if [[ -z "$FAILED_DEPLOYMENTS" ]]; then
    echo "No failed deployments found"
  else
    for deployment in $FAILED_DEPLOYMENTS; do
      echo -e "\n=== Deployment: $deployment ==="
      az deployment group show --resource-group "$rg" --name "$deployment" --output json \
        --query "{Name:name, State:properties.provisioningState, Timestamp:properties.timestamp, Error:properties.error, CorrelationId:properties.correlationId, Duration:properties.duration}"

      # Get deployment operations to see which specific resources failed
      echo -e "\nFailed Operations for deployment $deployment:"
      az deployment operation group list --resource-group "$rg" --name "$deployment" --output json \
        --query "[?properties.provisioningState!='Succeeded'].{State:properties.provisioningState, Target:properties.targetResource.resourceName, Type:properties.targetResource.resourceType, Status:properties.statusMessage}"
    done
  fi
done

# If we've gotten to this part, let's make sure this step is noticed by failing it
exit 1

