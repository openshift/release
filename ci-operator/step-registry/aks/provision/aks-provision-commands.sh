#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="${HYPERSHIFT_AZURE_LOCATION:-${LEASED_RESOURCE}}"

RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"

CLUSTER_AUTOSCALER_ARGS=""
if [[ "${ENABLE_CLUSTER_AUTOSCALER:-}" == "true" ]]; then
    CLUSTER_AUTOSCALER_ARGS="--enable-cluster-autoscaler"
fi

if [[ "${AKS_CLUSTER_AUTOSCALER_MIN_NODES:-}" != "" ]]; then
    CLUSTER_AUTOSCALER_ARGS+=" --min-count ${AKS_CLUSTER_AUTOSCALER_MIN_NODES}"
fi

if [[ "${AKS_CLUSTER_AUTOSCALER_MAX_NODES:-}" != "" ]]; then
    CLUSTER_AUTOSCALER_ARGS+=" --max-count ${AKS_CLUSTER_AUTOSCALER_MAX_NODES}"
fi

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

echo "Creating resource group for the aks cluster"
RESOURCEGROUP="${RESOURCE_NAME_PREFIX}-aks-rg"
az group create --name "$RESOURCEGROUP" --location "$AZURE_LOCATION"
echo "$RESOURCEGROUP" > "${SHARED_DIR}/resourcegroup_aks"

K8S_VERSION_ARGS=""
if [[ "${USE_LATEST_K8S_VERSION:-}" == "true" ]]; then
  K8S_LATEST_VERSION=$(az aks get-versions --location "${AZURE_LOCATION}" --output json --query 'max(orchestrators[*].orchestratorVersion)')
  K8S_VERSION_ARGS="--kubernetes-version ${K8S_LATEST_VERSION}"
fi

echo "Building up the aks create command"
CLUSTER="${RESOURCE_NAME_PREFIX}-aks-cluster"
AKS_CREATE_COMMAND=(
    az aks create
    --name "$CLUSTER"
    --resource-group "$RESOURCEGROUP"
    --node-count "$AKS_NODE_COUNT"
    --load-balancer-sku "$AKS_LB_SKU"
    --os-sku "$AKS_OS_SKU"
    "${CLUSTER_AUTOSCALER_ARGS:-}" \
    "${K8S_VERSION_ARGS:-}" \
    --location "$AZURE_LOCATION"
)

if [[ "$AKS_GENERATE_SSH_KEYS" == "true" ]]; then
    AKS_CREATE_COMMAND+=(--generate-ssh-keys)
fi

if [[ "$AKS_ENABLE_FIPS_IMAGE" == "true" ]]; then
    AKS_CREATE_COMMAND+=(--enable-fips-image)
fi

if [[ -n "$AKS_NODE_VM_SIZE" ]]; then
    AKS_CREATE_COMMAND+=(--node-vm-size "$AKS_NODE_VM_SIZE")
fi

if [[ -n "$AKS_ZONES" ]]; then
    AKS_CREATE_COMMAND+=(--zones "$AKS_ZONES")
fi

echo "Creating AKS cluster"
eval "${AKS_CREATE_COMMAND[*]}"
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
