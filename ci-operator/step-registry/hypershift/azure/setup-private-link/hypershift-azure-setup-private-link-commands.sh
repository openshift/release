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
#   1. hypershift-ci-jobs-self-managed-azure: broad credentials used for
#      infrastructure provisioning (VNet discovery, subnet creation).
#   2. hypershift-ci-jobs-self-managed-azure/private-credentials.json: dedicated
#      credentials with only the permissions needed by the HyperShift Operator
#      to manage Private Link Services. This is what gets passed to
#      --azure-private-creds during HO install, matching the customer experience.
#
# Required Azure RBAC for the private-link credential (scoped to mgmt RG):
#   - Microsoft.Network/privateLinkServices/read,write,delete
#   - Microsoft.Network/loadBalancers/read

# Login to Azure using the broad infra credentials (for subnet creation)
set +x
AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
set -x

# Dedicated private link credential for HO install
AZURE_PRIVATE_LINK_CREDS="/etc/hypershift-ci-jobs-self-managed-azure/private-credentials.json"

# Use the nested management cluster's kubeconfig
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"

# Discover the management cluster's resource groups.
# HyperShift Azure creates the VNet in a separate resource group (<name>-vnet-<infra-id>)
# from the main infra resource group (<name>-<infra-id>). The management cluster name
# (which doubles as the infra-id) is saved by the create-management-cluster step.
MGMT_CLUSTER_NAME=$(cat "${SHARED_DIR}/management_cluster_name")
MGMT_INFRA_RG=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
MGMT_VNET_RG="${MGMT_CLUSTER_NAME}-vnet-${MGMT_CLUSTER_NAME}"
echo "Management cluster name: ${MGMT_CLUSTER_NAME}"
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

# Create the NAT subnet for Private Link Services
# The subnet must have privateLinkServiceNetworkPolicies disabled to allow
# PLS NAT IP allocation. Uses 10.0.1.0/24 which is within the default
# VNet range (10.0.0.0/16) but doesn't overlap the default node subnet (10.0.0.0/24).
NAT_SUBNET_NAME="pls-nat-subnet"
NAT_SUBNET_CIDR="10.0.1.0/24"

echo "Creating NAT subnet ${NAT_SUBNET_NAME} (${NAT_SUBNET_CIDR}) in VNet ${MGMT_VNET}"
az network vnet subnet create \
  --resource-group "${VNET_RG}" \
  --vnet-name "${MGMT_VNET}" \
  --name "${NAT_SUBNET_NAME}" \
  --address-prefixes "${NAT_SUBNET_CIDR}" \
  --disable-private-link-service-network-policies true

NAT_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "${VNET_RG}" \
  --vnet-name "${MGMT_VNET}" \
  --name "${NAT_SUBNET_NAME}" \
  --query id -o tsv)

echo "NAT subnet ID: ${NAT_SUBNET_ID}"

# Save for downstream steps (hypershift-install and e2e test runner)
echo "${MGMT_INFRA_RG}" > "${SHARED_DIR}/azure_pls_resource_group"
echo "${NAT_SUBNET_ID}" > "${SHARED_DIR}/azure_private_nat_subnet_id"
echo "${AZURE_PRIVATE_LINK_CREDS}" > "${SHARED_DIR}/azure_private_link_creds_file"

echo "Azure Private Link infrastructure setup complete"
