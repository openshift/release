#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# This step creates a NAT subnet in the management cluster's VNet for
# Azure Private Link Service support. It discovers the management cluster's
# infrastructure resource group and VNet, creates a subnet with
# privateLinkServiceNetworkPolicies disabled, and writes the resource group,
# NAT subnet ID, and private link credentials path to SHARED_DIR for
# downstream steps.
#
# Two credential sets are used:
#   1. ${CLUSTER_PROFILE_DIR}/osServicePrincipal.json: broad credentials used for
#      infrastructure provisioning (VNet discovery, subnet creation).
#   2. hypershift-selfmanaged-azurecreds/private-credentials.json: dedicated
#      credentials with only the permissions needed by the HyperShift Operator
#      to manage Private Link Services. This is what gets passed to
#      --azure-private-creds during HO install, matching the customer experience.
#
# Required Azure RBAC for the private-link credential:
#   - Microsoft.Network/privateLinkServices/read,write,delete (scoped to mgmt infra RG)
#   - Microsoft.Network/loadBalancers/read (scoped to mgmt infra RG)
#   - Microsoft.Network/virtualNetworks/subnets/join/action (scoped to NAT subnet, granted below)

# Login to Azure using the broad infra credentials (for subnet creation)
set +x
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
set -x

# Dedicated private link credential for HO install
AZURE_PRIVATE_LINK_CREDS="/etc/hypershift-selfmanaged-azurecreds/private-credentials.json"

# Use azure management cluster's kubeconfig
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
MGMT_INFRA_RG=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
MGMT_VNET_RG=${MGMT_INFRA_RG}
echo "Management cluster infra resource group: ${MGMT_INFRA_RG}"
echo "Management cluster VNet resource group: ${MGMT_VNET_RG}"

# Find the VNet: try the VNet resource group first, then the infra RG as fallback
MGMT_VNET=$(az network vnet list --resource-group "${MGMT_VNET_RG}" --query '[0].name' -o tsv 2>/dev/null)
VNET_RG="${MGMT_VNET_RG}"
if [[ -z "${MGMT_VNET}" ]]; then
  echo "VNet not found in VNet RG, trying infra resource group"
  MGMT_VNET=$(az network vnet list --resource-group "${MGMT_INFRA_RG}" --query '[0].name' -o tsv 2>/dev/null)
  VNET_RG="${MGMT_INFRA_RG}"
fi
if [[ -z "${MGMT_VNET}" ]]; then
  echo "ERROR: Could not find management cluster VNet in resource group ${MGMT_VNET_RG} or ${MGMT_INFRA_RG}"
  exit 1
fi
echo "Management cluster VNet: ${MGMT_VNET} (resource group: ${VNET_RG})"

# Helper function to create subnet with a given CIDR
# Returns 0 on success, 1 on failure
try_create_nat_subnet() {
  local cidr=$1
  echo "Attempting to create NAT subnet with CIDR: ${cidr}"

  if az network vnet subnet create \
    --resource-group "${VNET_RG}" \
    --vnet-name "${MGMT_VNET}" \
    --name "${NAT_SUBNET_NAME}" \
    --address-prefixes "${cidr}" \
    --disable-private-link-service-network-policies true \
    --output none 2>/dev/null; then
    echo "Successfully created NAT subnet with CIDR: ${cidr}"
    return 0
  else
    echo "Failed to create subnet with CIDR: ${cidr} (likely occupied or no capacity)"
    return 1
  fi
}

# Create the NAT subnet for Private Link Services
# The subnet must have privateLinkServiceNetworkPolicies disabled to allow
# PLS NAT IP allocation. This cucushift-specific version tries multiple CIDR
# ranges to avoid conflicts, and auto-expands the VNet address space if needed.
NAT_SUBNET_NAME="pls-nat-subnet"

# Check if the NAT subnet already exists (from a previous run or pre-created)
EXISTING_NAT_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "${VNET_RG}" \
  --vnet-name "${MGMT_VNET}" \
  --name "${NAT_SUBNET_NAME}" \
  --query id -o tsv 2>/dev/null || true)

if [[ -n "${EXISTING_NAT_SUBNET_ID}" ]]; then
  echo "NAT subnet ${NAT_SUBNET_NAME} already exists, reusing it"
  NAT_SUBNET_ID="${EXISTING_NAT_SUBNET_ID}"
else
  echo "Creating NAT subnet in VNet ${MGMT_VNET}..."

  # Try creating subnet in 10.0.x.0/24 range (x=1..20)
  # Azure will fail if the CIDR is already occupied or no capacity available
  CREATED=false
  for i in {1..20}; do
    if try_create_nat_subnet "10.0.${i}.0/24"; then
      CREATED=true
      break
    fi
  done

  # If all 10.0.x.0/24 attempts failed, expand VNet address space and retry
  # Azure VNets can have multiple non-overlapping address spaces
  if [[ "${CREATED}" != "true" ]]; then
    echo "All 10.0.x.0/24 CIDRs are occupied or VNet is full"
    echo "Expanding VNet address space to include 172.16.0.0/16..."

    CURRENT_PREFIXES=$(az network vnet show \
      --resource-group "${VNET_RG}" \
      --name "${MGMT_VNET}" \
      --query 'addressSpace.addressPrefixes' -o tsv)

    az network vnet update \
      --resource-group "${VNET_RG}" \
      --name "${MGMT_VNET}" \
      --address-prefixes $CURRENT_PREFIXES "172.16.0.0/16" \
      --output none

    echo "VNet expanded, creating subnet in new address space..."

    # Try creating in the new 172.16.x.0/24 range
    for i in {0..10}; do
      if try_create_nat_subnet "172.16.${i}.0/24"; then
        CREATED=true
        break
      fi
    done

    if [[ "${CREATED}" != "true" ]]; then
      echo "ERROR: Failed to create NAT subnet even after VNet expansion"
      exit 1
    fi
  fi

  NAT_SUBNET_ID=$(az network vnet subnet show \
    --resource-group "${VNET_RG}" \
    --vnet-name "${MGMT_VNET}" \
    --name "${NAT_SUBNET_NAME}" \
    --query id -o tsv)
fi

echo "NAT subnet ID: ${NAT_SUBNET_ID}"

# Grant the private link service principal "Network Contributor" on the NAT subnet.
# Creating a PLS requires Microsoft.Network/virtualNetworks/subnets/join/action on
# the NAT subnet. The private link SP already has PLS write permissions on the infra
# RG, but the NAT subnet lives in the VNet RG — Azure's LinkedAuthorization check
# requires explicit permission on the linked subnet scope.
PRIVATE_SP_CLIENT_ID="$(<"${AZURE_PRIVATE_LINK_CREDS}" jq -r '.clientId')"
PRIVATE_SP_OBJECT_ID=$(az ad sp show --id "${PRIVATE_SP_CLIENT_ID}" --query id -o tsv)
echo "Granting Network Contributor on NAT subnet to private link SP (${PRIVATE_SP_CLIENT_ID})"
az role assignment create \
  --assignee-object-id "${PRIVATE_SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "${NAT_SUBNET_ID}"

# Save for downstream steps (hypershift-install and e2e test runner)
echo "${MGMT_INFRA_RG}" > "${SHARED_DIR}/azure_pls_resource_group"
echo "${NAT_SUBNET_ID}" > "${SHARED_DIR}/azure_private_nat_subnet_id"
echo "${AZURE_PRIVATE_LINK_CREDS}" > "${SHARED_DIR}/azure_private_link_creds_file"

echo "Azure Private Link infrastructure setup complete"
