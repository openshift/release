#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

CLUSTER="${NAMESPACE}-${UNIQUE_HASH}"
RESOURCEGROUP="$(<"${SHARED_DIR}/resourcegroup")"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

echo "Building up the aks create command"
AKE_CREATE_COMMAND=(
    az aks create
    --name "$CLUSTER"
    --resource-group "$RESOURCEGROUP"
    --node-count "$AKS_NODE_COUNT"
    --load-balancer-sku "$AKS_LB_SKU"
    --os-sku "$AKS_OS_SKU"
)

if [[ "$AKS_GENERATE_SSH_KEYS" == "true" ]]; then
    AKE_CREATE_COMMAND+=(--generate-ssh-keys)
fi

if [[ "$AKS_ENABLE_FIPS_IMAGE" == "true" ]]; then
    AKE_CREATE_COMMAND+=(--enable-fips-image)
fi

echo "Creating AKS cluster"
eval "${AKE_CREATE_COMMAND[*]}"
echo "$CLUSTER" > "${SHARED_DIR}/cluster-name"

echo "Building up the aks get-credentials command"
AKS_GET_CREDS_COMMAND=(
    az aks get-credentials
    --name "$CLUSTER"
    --resource-group "$RESOURCEGROUP"
)

if [[ "$AKS_ENABLE_FIPS_IMAGE" == "true" ]]; then
    AKS_GET_CREDS_COMMAND+=(--overwrite-existing)
fi

echo "Getting kubeconfig to the AKS cluster"
# shellcheck disable=SC2034
KUBECONFIG="${SHARED_DIR}/kubeconfig"
eval "${AKS_GET_CREDS_COMMAND[*]}"
oc get nodes
