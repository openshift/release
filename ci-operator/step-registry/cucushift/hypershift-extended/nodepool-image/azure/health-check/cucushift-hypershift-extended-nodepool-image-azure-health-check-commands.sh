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

    local vm_name="$1"
    local vm_image_file="/tmp/vm-${vm_name}.json"
    local vm_image_version=""
    local vm_image_offer=""
    local vm_image_publisher=""
    local vm_image_sku=""

    az vm get-instance-view -g "$HC_RG" --name "$1" --query "storageProfile.imageReference" > "/tmp/vm-${vm_name}.json"

    vm_image_version="$(jq -r .version "$vm_image_file")"
    vm_image_offer="$(jq -r .offer "$vm_image_file")"
    vm_image_publisher="$(jq -r .publisher "$vm_image_file")"
    vm_image_sku="$(jq -r .sku "$vm_image_file")"
    assert_equal vm_image_version IMAGE_VERSION
    assert_equal vm_image_sku IMAGE_SKU
    assert_equal vm_image_offer HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER
    assert_equal vm_image_publisher HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER
}

##### Main #####

if [[ -z $HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER ]]; then
    echo "\$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER is empty, skip"
    exit 0
fi

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="$LEASED_RESOURCE"

IMAGE_SKU=$(<"${SHARED_DIR}"/azure-marketplace-image-sku)
IMAGE_VERSION=$(<"${SHARED_DIR}"/azure-marketplace-image-version)

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

echo "Checking vm image"
HC_NODES="$(KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig oc get node -o jsonpath='{.items[*].metadata.name}')"
HC_RG="$(oc get hc -A -o jsonpath='{.items[0].spec.platform.azure.resourceGroup}')"
for HC_NODE in $HC_NODES; do
    check_vm_image "$HC_NODE"
done
