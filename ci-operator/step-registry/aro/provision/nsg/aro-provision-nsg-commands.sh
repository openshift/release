#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER="${NAMESPACE}-${UNIQUE_HASH}"
RESOURCEGROUP=$(cat "${SHARED_DIR}/resourcegroup")
VNET=${VNET:=$(cat "${SHARED_DIR}"/vnet)}
LOCATION=${LOCATION:=${LEASED_RESOURCE}}
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
MASTER_SUBNET_NAME=$(yq-go r ${SHARED_DIR}/customer_vnet_subnets.yaml 'platform.azure.controlPlaneSubnet')
WORKER_SUBNET_NAME=$(yq-go r ${SHARED_DIR}/customer_vnet_subnets.yaml 'platform.azure.computeSubnet')
NSG=${NSG:=${CLUSTER}-nsg}
NSG_OPEN_PORTS=${NSG_OPEN_PORTS:="80 443 6443"}

echo "Logging into Azure Cloud"
# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

echo "Creating nsg: ${NSG} in resource group ${RESOURCEGROUP} in location: ${LOCATION}"
az network nsg create -g "${RESOURCEGROUP}" -n "${NSG}"
az network nsg rule create -g "${RESOURCEGROUP}" --nsg-name "${NSG}" -n "${NSG}-allow" --priority 1000 --access Allow --source-port-ranges "*" --destination-port-ranges ${NSG_OPEN_PORTS}
echo "Updating ${MASTER_SUBNET_NAME} in vnet ${VNET}, attaching ${NSG}"
az network vnet subnet update -g "${RESOURCEGROUP}" -n "${MASTER_SUBNET_NAME}" --vnet-name "${VNET}" --network-security-group "${NSG}"
echo "Updating ${WORKER_SUBNET_NAME} in vnet ${VNET}, attaching ${NSG}"
az network vnet subnet update -g "${RESOURCEGROUP}" -n "${WORKER_SUBNET_NAME}" --vnet-name "${VNET}" --network-security-group "${NSG}"



