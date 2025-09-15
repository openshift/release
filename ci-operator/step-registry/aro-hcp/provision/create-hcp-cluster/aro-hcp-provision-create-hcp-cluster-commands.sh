#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

# read the secrets and login as the user
export TEST_USER_CLIENT_ID; TEST_USER_CLIENT_ID=$(cat /var/run/hcp-integration-credentials/client-id)
export TEST_USER_CLIENT_SECRET; TEST_USER_CLIENT_SECRET=$(cat /var/run/hcp-integration-credentials/client-secret)
export TEST_USER_TENANT_ID; TEST_USER_TENANT_ID=$(cat /var/run/hcp-integration-credentials/tenant)
az login --service-principal -u "${TEST_USER_CLIENT_ID}" -p "${TEST_USER_CLIENT_SECRET}" --tenant "${TEST_USER_TENANT_ID}"

export CUSTOMER_RG_NAME; CUSTOMER_RG_NAME=$(cat "${SHARED_DIR}/customer-resource-group-name.txt")
MANAGED_RESOURCE_GROUP="${CUSTOMER_RG_NAME}-rg-managed"

# updated to match https://github.com/Azure/ARO-HCP/pull/2423/commits/d39769ee931c849059fad9fee025d1d9840089a1
KEYVAULT_NAME=$(az deployment group show \
  --name 'infra' \
  --subscription "${SUBSCRIPTION}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --query "properties.outputs.keyVaultName.value" -o tsv)

az deployment group create \
  --name 'aro-hcp'\
  --subscription "${SUBSCRIPTION}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --template-file demo/bicep/cluster.bicep \
  --parameters \
    vnetName="${CUSTOMER_VNET_NAME}" \
    subnetName="${CUSTOMER_VNET_SUBNET1}" \
    nsgName="${CUSTOMER_NSG}" \
    clusterName="${CLUSTER_NAME}" \
    managedResourceGroupName="${MANAGED_RESOURCE_GROUP}" \
    keyVaultName="${KEYVAULT_NAME}"
