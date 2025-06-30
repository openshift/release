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


# Defined here because it's used here.
is_int_testing_subscription() {
    return "$(test "$(az account show --query name --output tsv)" = "ARO SRE Team - INT (EA Subscription 3)")"
}

if is_int_testing_subscription; then
    export FRONTEND_HOST; FRONTEND_HOST=$(az cloud show --query endpoints.resourceManager --output tsv)
else
    export FRONTEND_HOST; FRONTEND_HOST="http://localhost:8443"
fi

export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(az account show --query id --output tsv)
export TENANT_ID; TENANT_ID=$(az account show --query tenantId --output tsv)
MANAGED_RESOURCE_GROUP="$CLUSTER_NAME-rg-03"

export SUBSCRIPTION_RESOURCE_ID; SUBSCRIPTION_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}"
export RESOURCE_GROUP_RESOURCE_ID; RESOURCE_GROUP_RESOURCE_ID="${SUBSCRIPTION_RESOURCE_ID}/resourceGroups/${CUSTOMER_RG_NAME}"
export CLUSTER_RESOURCE_ID; CLUSTER_RESOURCE_ID="${RESOURCE_GROUP_RESOURCE_ID}/providers/Microsoft.RedHatOpenShift/hcpOpenShiftClusters/${CLUSTER_NAME}"
export NODE_POOL_RESOURCE_ID; NODE_POOL_RESOURCE_ID="${CLUSTER_RESOURCE_ID}/nodePools/${NP_NAME}"


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

az deployment group create \
  --name 'node-pool' \
  --subscription "${SUBSCRIPTION}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --template-file demo/bicep/nodepool.bicep \
  --parameters \
    clusterName="${CLUSTER_NAME}" \
    nodePoolName="${NP_NAME}"
