#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#echo "Installing oc binary"
#curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz | tar zxvf - oc
#chmod +x oc
CLUSTER=${CLUSTER:="${NAMESPACE}-${UNIQUE_HASH}"}
RESOURCEGROUP=${RESOURCEGROUP:=$(cat "${SHARED_DIR}/resourcegroup")}
VNET=${VNET:=${CLUSTER}-vnet}
LOCATION=${LOCATION:=${LEASED_RESOURCE}}
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

echo $VNET > $SHARED_DIR/vnet

# get az-cli, do feature adds for cloud if needed
# 
echo "Logging into Azure Cloud"
# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

echo "Creating vnet: ${VNET} in resource group ${RESOURCEGROUP} in location: ${LOCATION}"
# see https://raw.githubusercontent.com/openshift/osde2e/main/ci/create-aro-cluster.sh
# create the resourcegroup to contain the cluster object and vnet
az group create \
    --name $RESOURCEGROUP \
    --location $LOCATION
    
az network vnet create \
    --resource-group $RESOURCEGROUP \
    --name $VNET \
    --address-prefixes 10.0.0.0/22

az network vnet subnet create \
    --resource-group $RESOURCEGROUP \
    --vnet-name $VNET \
    --name master-subnet \
    --address-prefixes 10.0.0.0/23 \
    --service-endpoints Microsoft.ContainerRegistry

az network vnet subnet create \
    --resource-group $RESOURCEGROUP \
    --vnet-name $VNET \
    --name worker-subnet \
    --address-prefixes 10.0.2.0/23 \
    --service-endpoints Microsoft.ContainerRegistry
    
az network vnet subnet update \
    --name master-subnet \
    --resource-group $RESOURCEGROUP \
    --vnet-name $VNET \
    --disable-private-link-service-network-policies true

