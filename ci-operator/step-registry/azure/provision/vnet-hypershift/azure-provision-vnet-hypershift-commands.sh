#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="${HYPERSHIFT_AZURE_LOCATION:-${LEASED_RESOURCE}}"

RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

echo "Creating NSG in its own RG"
NSG_NAME="${RESOURCE_NAME_PREFIX}-nsg"
NSG_RESOURCE_GROUP="${RESOURCE_NAME_PREFIX}-nsg-rg"
az group create --name "$NSG_RESOURCE_GROUP" --location "$AZURE_LOCATION"
echo "$NSG_RESOURCE_GROUP" > "${SHARED_DIR}/resourcegroup_nsg"

az network nsg create --name "$NSG_NAME" --resource-group "$NSG_RESOURCE_GROUP" --location "$AZURE_LOCATION"
NSG_ID="$(az network nsg list --query "[?name=='${NSG_NAME}'].id" -o tsv)"
echo "$NSG_ID" > "${SHARED_DIR}/azure_nsg_id"

echo "Creating VNET in its own RG"
VNET_NAME="${RESOURCE_NAME_PREFIX}-vnet"
VNET_RESOURCE_GROUP="${RESOURCE_NAME_PREFIX}-vnet-rg"
VNET_ADDRESS_PREFIX="10.0.0.0/16"
az group create --name "$VNET_RESOURCE_GROUP" --location "$AZURE_LOCATION"
echo "$VNET_RESOURCE_GROUP" > "${SHARED_DIR}/resourcegroup_vnet"

az network vnet create --name "$VNET_NAME" --resource-group "$VNET_RESOURCE_GROUP" --location "$AZURE_LOCATION" \
    --address-prefixes "$VNET_ADDRESS_PREFIX"
VNET_ID="$(az network vnet list --query "[?name=='${VNET_NAME}'].id" -o tsv)"
echo "$VNET_ID" > "${SHARED_DIR}/azure_vnet_id"

echo "Creating a subnet within the VNET and its RG"
SUBNET_NAME="${RESOURCE_NAME_PREFIX}-subnet"
SUBNET_ADDRESS_PREFIX="10.0.0.0/24"
az network vnet subnet create --name "$SUBNET_NAME" --resource-group "$VNET_RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
    --address-prefix "$SUBNET_ADDRESS_PREFIX" --network-security-group "$NSG_ID"
SUBNET_ID="$(az network vnet subnet list --vnet-name "$VNET_NAME" --resource-group "$VNET_RESOURCE_GROUP" \
    --query "[?name=='${SUBNET_NAME}'].id" -o tsv)"
echo "$SUBNET_ID" > "${SHARED_DIR}/azure_subnet_id"
