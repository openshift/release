#!/usr/bin/env bash

set -euo pipefail

if [[ -z $HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER ]]; then
    echo "\$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER is empty, skip"
    exit 0
fi

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="$LEASED_RESOURCE"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

IMAGE_JSON=/tmp/azure-marketplace-image.json
IMAGE_SKU_FILE="${SHARED_DIR}"/azure-marketplace-image-sku
IMAGE_VERSION_FILE="${SHARED_DIR}"/azure-marketplace-image-version
PULL_SECRET="${CLUSTER_PROFILE_DIR}"/pull-secret
WRITABLE_PULL_SECRET=/tmp/pull-secret

echo "Getting pull secret"
cp "$PULL_SECRET" "$WRITABLE_PULL_SECRET"
KUBECONFIG="" oc registry login --to "$WRITABLE_PULL_SECRET"

echo "Extracting OCP version from release image"
OCP_MAJOR_VERSION=$(oc adm release info "$RELEASE_IMAGE_LATEST" -a "$WRITABLE_PULL_SECRET" -o json | jq -r '.metadata.version' | cut -d . -f 1)
OCP_MINOR_VERSION=$(oc adm release info "$RELEASE_IMAGE_LATEST" -a "$WRITABLE_PULL_SECRET" -o json | jq -r '.metadata.version' | cut -d . -f 2)

echo "Extracting Azure marketplace image info"
az vm image list \
    --architecture "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_ARCH" \
    --publisher "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_PUBLISHER" \
    --offer "$HYPERSHIFT_AZURE_MARKETPLACE_IMAGE_OFFER" \
    --sku "aro_${OCP_MAJOR_VERSION}${OCP_MINOR_VERSION}" \
    --location "$AZURE_LOCATION" \
    --all \
    -o json | jq -r 'max_by(.version)' > "$IMAGE_JSON"

echo "Storing image info"
jq -r .sku "$IMAGE_JSON" > "$IMAGE_SKU_FILE"
jq -r .version "$IMAGE_JSON" > "$IMAGE_VERSION_FILE"
