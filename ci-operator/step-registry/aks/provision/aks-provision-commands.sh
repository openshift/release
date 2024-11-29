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

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

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

CERT_ROTATION_ARGS=""
if [[ "${ENABLE_AKS_CERT_ROTATION:-}" == "true" ]]; then
    CERT_ROTATION_ARGS+=" --enable-secret-rotation"

    if [[ "${AKS_CERT_ROTATION_POLL_INTERVAL:-}" != "" ]]; then
        CERT_ROTATION_ARGS+=" --rotation-poll-interval ${AKS_CERT_ROTATION_POLL_INTERVAL}"
    fi
fi

echo "Creating resource group for the aks cluster"
RESOURCEGROUP="${RESOURCE_NAME_PREFIX}-aks-rg"
az group create --name "$RESOURCEGROUP" --location "$AZURE_LOCATION"
echo "$RESOURCEGROUP" > "${SHARED_DIR}/resourcegroup_aks"

echo "Building up the aks create command"
CLUSTER="${RESOURCE_NAME_PREFIX}-aks-cluster"
AKS_CREATE_COMMAND=(
    az aks create
    --name "$CLUSTER"
    --resource-group "$RESOURCEGROUP"
    --node-count "$AKS_NODE_COUNT"
    --load-balancer-sku "$AKS_LB_SKU"
    --os-sku "$AKS_OS_SKU"
    "${CLUSTER_AUTOSCALER_ARGS:-}"
    "${CERT_ROTATION_ARGS:-}"
    --location "$AZURE_LOCATION"
)

if [[ -n "$AKS_ADDONS" ]]; then
     AKS_CREATE_COMMAND+=(--enable-addons "$AKS_ADDONS")
fi

# Version prioritization: specific > latest > default
if [[ -n "$AKS_K8S_VERSION" ]]; then
    AKS_CREATE_COMMAND+=(--kubernetes-version "$AKS_K8S_VERSION")
elif [[ "$USE_LATEST_K8S_VERSION" == "true" ]]; then
    K8S_LATEST_VERSION=$(az aks get-versions --location "${AZURE_LOCATION}" --output json --query 'max(orchestrators[*].orchestratorVersion)')
    AKS_CREATE_COMMAND+=(--kubernetes-version "$K8S_LATEST_VERSION")
fi

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

echo "Saving cluster info"
echo "$CLUSTER" > "${SHARED_DIR}/cluster-name"
if [[ $AKS_ADDONS == *azure-keyvault-secrets-provider* ]]; then
    az aks show -n "$CLUSTER" -g "$RESOURCEGROUP" | jq .addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -r > "${SHARED_DIR}/aks_keyvault_secrets_provider_client_id"
    # Grant MI required permissions to the KV which will be created in the same RG as the AKS cluster
    AKS_KV_SECRETS_PROVIDER_OBJECT_ID="$(az aks show -n "$CLUSTER" -g "$RESOURCEGROUP" | jq .addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -r)"
    RG_ID="$(az group show -n "$RESOURCEGROUP" --query id -o tsv)"
    az role assignment create --assignee-object-id "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" --role "Key Vault Secrets User" --scope "${RG_ID}" --assignee-principal-type ServicePrincipal
fi

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
oc version