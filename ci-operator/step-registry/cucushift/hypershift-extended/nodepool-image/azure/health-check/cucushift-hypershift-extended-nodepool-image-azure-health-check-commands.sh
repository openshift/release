#!/usr/bin/env bash

# shellcheck disable=SC2034

set -euo pipefail

# Inputs:
# $1: name of the first global variable
# $2: name of the second global variable
function assert_equal() {
    if [[ -z "$1" ]]; then
        echo "The first variable's name must not be empty" >&2
        return 1
    fi
    if [[ -z "$2" ]]; then
        echo "The second variable's name must not be empty" >&2
        return 1
    fi

    if [[ "${!1}" != "${!2}" ]]; then
        echo "Error: $1=${!1} != $2=${!2}" >&2
        return 1
    fi
}

# Inputs:
# $1: name of the VM
function check_vm_image() {
    if [[ -z "$1" ]]; then
        echo "The VM name must not be empty" >&2
        return 1
    fi

    local np_name=""
    local vm_name="$1"
    local vm_image_file="/tmp/vm-${vm_name}.json"
    local vm_image_version=""
    local vm_image_offer=""
    local vm_image_publisher=""
    local vm_image_sku=""

    az vm get-instance-view -g "$HC_RG" --name "$1" --query "storageProfile.imageReference" > "$vm_image_file"
    vm_image_version="$(jq -r .version "$vm_image_file")"
    vm_image_offer="$(jq -r .offer "$vm_image_file")"
    vm_image_publisher="$(jq -r .publisher "$vm_image_file")"
    vm_image_sku="$(jq -r .sku "$vm_image_file")"

    np_name=$(KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc get node "$vm_name" -o jsonpath='{.metadata.labels.hypershift\.openshift\.io/nodePool}')
    if [[ $np_name == "$EXTRA_NODEPOOL_NAME" ]]; then
        echo "Checking VM $vm_name of extra NodePool $EXTRA_NODEPOOL_NAME"
        assert_equal vm_image_version IMAGE_VERSION_EXTRA
        assert_equal vm_image_offer IMAGE_OFFER_EXTRA
        assert_equal vm_image_publisher IMAGE_PUBLISHER_EXTRA
        assert_equal vm_image_sku IMAGE_SKU_EXTRA
    else
        echo "Checking VM $vm_name of NodePool $np_name"
        assert_equal vm_image_version IMAGE_VERSION
        assert_equal vm_image_offer IMAGE_OFFER
        assert_equal vm_image_publisher IMAGE_PUBLISHER
        assert_equal vm_image_sku IMAGE_SKU
    fi
}

##### Main #####

if [[ ! -f "${SHARED_DIR}/azure-marketplace-image-publisher" ]]; then
    echo "${SHARED_DIR}/azure-marketplace-image-publisher not found, skipping the step"
    exit 0
fi

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

IMAGE_OFFER=$(<"${SHARED_DIR}"/azure-marketplace-image-offer)
IMAGE_OFFER_EXTRA=$(<"${SHARED_DIR}"/azure-marketplace-image-offer-extra)
IMAGE_PUBLISHER=$(<"${SHARED_DIR}"/azure-marketplace-image-publisher)
IMAGE_PUBLISHER_EXTRA=$(<"${SHARED_DIR}"/azure-marketplace-image-publisher-extra)
IMAGE_SKU=$(<"${SHARED_DIR}"/azure-marketplace-image-sku)
IMAGE_SKU_EXTRA=$(<"${SHARED_DIR}"/azure-marketplace-image-sku-extra)
IMAGE_VERSION=$(<"${SHARED_DIR}"/azure-marketplace-image-version)
IMAGE_VERSION_EXTRA=$(<"${SHARED_DIR}"/azure-marketplace-image-version-extra)

EXTRA_NODEPOOL_NAME=""
if [[ -f "$SHARED_DIR"/hypershift_extra_nodepool_name ]]; then
    EXTRA_NODEPOOL_NAME=$(<"$SHARED_DIR"/hypershift_extra_nodepool_name)
fi

echo "Checking VM image"
HC_NODES="$(KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc get node -o jsonpath='{.items[*].metadata.name}')"
HC_RG="$(oc get hc -A -o jsonpath='{.items[0].spec.platform.azure.resourceGroup}')"
for HC_NODE in $HC_NODES; do
    check_vm_image "$HC_NODE"
done
