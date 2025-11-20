#!/bin/bash

set -x

if [ "$ENABLEPEERPODS" != "true" ]; then
    echo "skip as ENABLEPEERPODS is not true"
    exit 0
fi

# Switch to a directory with rw permission
cd /tmp || exit 1

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS:-}" == "true" ]]; then
  AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

AZURE_RESOURCE_GROUP="$(cat "${SHARED_DIR}/resourcegroup")"
AZURE_VNET_NAME="$(cat "${SHARED_DIR}/vnet")"
WORKER_SUBNET_NAME=${WORKER_SUBNET_NAME:="worker-subnet"}

cat > "${SHARED_DIR}/peerpods_creds" << EOF
export AZURE_CLIENT_ID="${AZURE_CLIENT_ID}"
export AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET}"
export AZURE_TENANT_ID="${AZURE_TENANT_ID}"
export AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
export AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"
EOF


az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

AZURE_REGION="${LOCATION:=${LEASED_RESOURCE}}"

az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

PP_REGION="${AZURE_REGION}"
echo "Using the current region ${AZURE_REGION}"
PP_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"
PP_VNET_NAME="${AZURE_VNET_NAME}"
PP_SUBNET_NAME="${WORKER_SUBNET_NAME}"

az network public-ip create \
	--resource-group "${PP_RESOURCE_GROUP}" \
	--name MyPublicIP \
	--sku Standard \
	--allocation-method Static
az network nat gateway create \
	--resource-group "${PP_RESOURCE_GROUP}" \
	--name MyNatGateway \
	--public-ip-addresses MyPublicIP \
	--idle-timeout 10
az network vnet subnet update \
	--resource-group "${PP_RESOURCE_GROUP}" \
	--vnet-name "${PP_VNET_NAME}" \
	--name "${PP_SUBNET_NAME}" \
	--nat-gateway MyNatGateway
