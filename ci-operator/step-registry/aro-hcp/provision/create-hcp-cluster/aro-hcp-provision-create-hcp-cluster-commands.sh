#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

# read the secrets and login as the user
export TEST_USER_CLIENT_ID; TEST_USER_CLIENT_ID=$(cat /var/run/hcp-integration-credentials/client-id)
export TEST_USER_CLIENT_SECRET; TEST_USER_CLIENT_SECRET=$(cat /var/run/hcp-integration-credentials/client-secret)
export TEST_USER_TENANT_ID; TEST_USER_TENANT_ID=$(cat /var/run/hcp-integration-credentials/tenant)
az login --service-principal -u "${TEST_USER_CLIENT_ID}" -p "${TEST_USER_CLIENT_SECRET}" --tenant "${TEST_USER_TENANT_ID}"

MANAGED_RESOURCE_GROUP="$CLUSTER_NAME-rg-managed"

NSG_ID=$(az deployment group show \
          --name 'infra' \
          --subscription "${SUBSCRIPTION}" \
          --resource-group "${CUSTOMER_RG_NAME}" \
          --query "properties.outputs.networkSecurityGroupId.value" -o tsv)

SUBNET_ID=$(az deployment group show \
          --name 'infra' \
          --subscription "${SUBSCRIPTION}" \
          --resource-group "${CUSTOMER_RG_NAME}" \
          --query "properties.outputs.subnetId.value" -o tsv)

az deployment group create \
  --name 'aro-hcp'\
  --subscription "${SUBSCRIPTION}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --template-file demo/bicep/cluster.bicep \
  --parameters \
    networkSecurityGroupId="${NSG_ID}" \
    subnetId="${SUBNET_ID}" \
    clusterName="${CLUSTER_NAME}" \
    managedResourceGroupName="${MANAGED_RESOURCE_GROUP}"
