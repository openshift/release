#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function NAT_for_UDR() {
    local RG="$1" VNET="$2" masterSubnet="$3" workerSubnet="$4"
    NATPIPNAME="NATPIP"
    NATNAME="NATOutbound"

    #Create standard sku Public IP for NAT Gateway
    run_command "az network public-ip create -g $RG -n $NATPIPNAME --sku standard" &&
    sleep 60 &&
    #Create NAT Gateway and assign the NAT PIP to it
    run_command "az network nat gateway create -g $RG -n $NATNAME --public-ip-addresses $NATPIPNAME --idle-timeout 10" &&
    sleep 60 &&
    #Assign NAT Gateway for the internet egress to the master and worker subnets
    run_command "az network vnet subnet update -g $RG --vnet-name $VNET --name $masterSubnet --nat-gateway $NATNAME" &&
    run_command "az network vnet subnet update -g $RG --vnet-name $VNET --name $workerSubnet --nat-gateway $NATNAME" || exit 2
}

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

if [ X"${OUTBOUND_UDR_TYPE}" == X"NAT" ]; then
  echo "Use NAT for UserDefinedRouting..."
  VNET_FILE="${SHARED_DIR}/customer_vnet_subnets.yaml"
  RESOURCE_GROUP=$(cat ${SHARED_DIR}/resourcegroup)
  vnet_name=$(yq-go r ${VNET_FILE} 'platform.azure.virtualNetwork')
  controlPlaneSubnet=$(yq-go r ${VNET_FILE} 'platform.azure.controlPlaneSubnet')
  computeSubnet=$(yq-go r ${VNET_FILE} 'platform.azure.computeSubnet')
  NAT_for_UDR "$RESOURCE_GROUP" "$vnet_name" "$controlPlaneSubnet" "$computeSubnet" || exit 3
else
  echo "UserDefinedRouting is enabled, but does not define steps here, leave them for user"
fi
