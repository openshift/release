#!/usr/bin/env bash

set -euo pipefail

if [[ -z $HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER ]]; then
    echo "\$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER is empty, skip"
    exit 0
fi

function get_image_info() {
    local arch="$1"
    local sku=""

    case "$arch" in
    x64)
        sku="aro_${OCP_VERSION}"
        ;;
    Arm64)
        sku="${OCP_VERSION}-arm"
        ;;
    *)
        echo "Unsupported arch $arch" >&2
        return 1
        ;;
    esac

    az vm image list \
        --architecture "$arch" \
        --publisher "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER" \
        --offer "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER" \
        --sku "$sku" \
        --location "$AZURE_LOCATION" \
        --all \
        -o json | jq -r 'max_by(.version)'
}

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="${HYPERSHIFT_AZURE_LOCATION:-${LEASED_RESOURCE}}"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

IMAGE_JSON=/tmp/azure-marketplace-image.json
IMAGE_JSON_EXTRA=/tmp/azure-marketplace-image-extra.json
IMAGE_OFFER_FILE="${SHARED_DIR}"/azure-marketplace-image-offer
IMAGE_OFFER_FILE_EXTRA="${SHARED_DIR}"/azure-marketplace-image-offer-extra
IMAGE_PUBLISHER_FILE="${SHARED_DIR}"/azure-marketplace-image-publisher
IMAGE_PUBLISHER_FILE_EXTRA="${SHARED_DIR}"/azure-marketplace-image-publisher-extra
IMAGE_SKU_FILE="${SHARED_DIR}"/azure-marketplace-image-sku
IMAGE_SKU_FILE_EXTRA="${SHARED_DIR}"/azure-marketplace-image-sku-extra
IMAGE_VERSION_FILE="${SHARED_DIR}"/azure-marketplace-image-version
IMAGE_VERSION_FILE_EXTRA="${SHARED_DIR}"/azure-marketplace-image-version-extra
PULL_SECRET="${CLUSTER_PROFILE_DIR}"/pull-secret
PULL_SECRET_WRITABLE=/tmp/pull-secret

echo "Getting pull secret"
cp "$PULL_SECRET" "$PULL_SECRET_WRITABLE"
KUBECONFIG="" oc registry login --to "$PULL_SECRET_WRITABLE"

echo "Extracting OCP version from release image"
OCP_MAJOR_VERSION=$(oc adm release info "$RELEASE_IMAGE_LATEST" -a "$PULL_SECRET_WRITABLE" -o json | jq -r '.metadata.version' | cut -d . -f 1)
OCP_MINOR_VERSION=$(oc adm release info "$RELEASE_IMAGE_LATEST" -a "$PULL_SECRET_WRITABLE" -o json | jq -r '.metadata.version' | cut -d . -f 2)
OCP_VERSION="${HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OCP_VERSION:-${OCP_MAJOR_VERSION}${OCP_MINOR_VERSION}}"

echo "Extracting image info"
get_image_info "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_ARCH" > "$IMAGE_JSON"
jq -r .sku "$IMAGE_JSON" > "$IMAGE_SKU_FILE"
jq -r .version "$IMAGE_JSON" > "$IMAGE_VERSION_FILE"
echo "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER" > "$IMAGE_OFFER_FILE"
echo "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER" > "$IMAGE_PUBLISHER_FILE"

echo "Extracting extra image info"
get_image_info "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_ARCH_EXTRA" > "$IMAGE_JSON_EXTRA"
jq -r .sku "$IMAGE_JSON_EXTRA" > "$IMAGE_SKU_FILE_EXTRA"
jq -r .version "$IMAGE_JSON_EXTRA" > "$IMAGE_VERSION_FILE_EXTRA"
echo "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER" > "$IMAGE_OFFER_FILE_EXTRA"
echo "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER" > "$IMAGE_PUBLISHER_FILE_EXTRA"
