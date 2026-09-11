#!/bin/bash
set -xeuo pipefail

if [[ ${HYPERSHIFT_AZURE_MARKETPLACE_ENABLED} == "true" ]]; then
  echo "SKIP for marketplace enabled when creating hosted cluster ....."
  exit 0
fi

if [ ! -f "${SHARED_DIR}/mgmt_kubeconfig" ]; then
    exit 1
fi

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "hostedclusters => ns: $HYPERSHIFT_NAMESPACE , cluster_name: $CLUSTER_NAME"

echo "Get marketplace info in the NodePool"
marketplace_info=$(oc get nodepool/"$CLUSTER_NAME" -n "$HYPERSHIFT_NAMESPACE" -ojsonpath='{.spec.platform.azure.image.azureMarketplace}')
gen=$(echo "$marketplace_info" | jq -r '.imageGeneration')
offer=$(echo "$marketplace_info" | jq -r '.offer')
sku=$(echo "$marketplace_info" | jq -r '.sku')
version=$(echo "$marketplace_info" | jq -r '.version')

if [[ -n "${HYPERSHIFT_AZURE_IMAGE_GENERATION:-}" && "$HYPERSHIFT_AZURE_IMAGE_GENERATION" != "$gen" ]]; then
    echo "image generation mismatch"
    exit 1 
fi

echo "Get marketplace info from installer bootimages"
#Hosted cluster creation without explicit marketplace flags correctly defaults to Gen2 
target_gen="${HYPERSHIFT_AZURE_IMAGE_GENERATION:-Gen2}"
target_offer=$(eval "oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml |     yq-v4  '.data.stream | fromjson | .architectures.x86_64.rhel-coreos-extensions.marketplace.azure.no-purchase-plan.\"hyperV$gen\".offer' -")
target_sku=$(eval "oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml |     yq-v4  '.data.stream | fromjson | .architectures.x86_64.rhel-coreos-extensions.marketplace.azure.no-purchase-plan.\"hyperV$gen\".sku' -")
target_version=$(eval "oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml |     yq-v4  '.data.stream | fromjson | .architectures.x86_64.rhel-coreos-extensions.marketplace.azure.no-purchase-plan.\"hyperV$gen\".version' -")

compare_marketplace_info() {
    local current_gen=$1
    local current_offer=$2
    local current_sku=$3
    local current_version=$4
    local target_gen=$5
    local target_offer=$6
    local target_sku=$7
    local target_version=$8

    if [ "$current_gen" = "$target_gen" ] && \
       [ "$current_offer" = "$target_offer" ] && \
       [ "$current_sku" = "$target_sku" ] && \
       [ "$current_version" = "$target_version" ]; then
        return 0  
    else
        return 1  
    fi
}

if compare_marketplace_info "$gen" "$offer" "$sku" "$version" "$target_gen" "$target_offer" "$target_sku" "$target_version"; then
    echo "[SUCCESS] Azure Marketplace configuration validation passed"
else
    echo "[ERROR] Azure Marketplace configuration mismatch"
    exit 1 
fi