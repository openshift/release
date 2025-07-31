#!/usr/bin/env bash

set -e
set -u
set -o pipefail

echo "[$(date -u --rfc-3339=seconds)] Resolving latest bundle image..."
BUNDLE_REPO="quay.io/redhat-user-workloads/kueue-operator-tenant/kueue-bundle-1-0"
BUNDLE_IMAGE=$(skopeo list-tags docker://$BUNDLE_REPO | jq -r '.Tags[]' | grep -E '^[a-f0-9]{40}$' | while read -r tag; do
    created=$(skopeo inspect docker://$BUNDLE_REPO:$tag 2>/dev/null | jq -r '.Created')
    if [ "$created" != "null" ] && [ -n "$created" ]; then echo "$created $tag"; fi
done | sort | tail -n1 | awk -v repo="$BUNDLE_REPO" '{print repo ":" $2}')

if [[ -z "$BUNDLE_IMAGE" ]]; then
    echo "ERROR: Failed to resolve BUNDLE_IMAGE from $BUNDLE_REPO"
    exit 1
fi

echo "Resolved BUNDLE_IMAGE: ${BUNDLE_IMAGE}"
echo "export BUNDLE_IMAGE=${BUNDLE_IMAGE}" >> "${SHARED_DIR}/env"

echo "[$(date -u --rfc-3339=seconds)] Extracting CSV image references from bundle..."
TEMP_BUNDLE_DIR="/tmp/bundle-extract"
mkdir -p "${TEMP_BUNDLE_DIR}"

# Extract bundle using skopeo.
echo "Extracting bundle: ${BUNDLE_IMAGE}"
if ! skopeo copy docker://${BUNDLE_IMAGE} dir:${TEMP_BUNDLE_DIR}; then
    echo "ERROR: Failed to extract bundle using skopeo"
    exit 1
fi

# Extract the bundle layers to get the manifests.
cd "${TEMP_BUNDLE_DIR}"
echo "Files in bundle directory:"
ls -la

LAYER_FILE=$(find . -name "*[0-9a-f]*" | grep -v manifest.json | grep -v version | grep -v "\.json$" | xargs ls -la | sort -k5 -nr | head -1 | awk '{print $9}')
if [[ -n "${LAYER_FILE}" ]]; then
    echo "Extracting layer: ${LAYER_FILE}"
    tar -xf "${LAYER_FILE}"

    # Look for CSV file
    CSV_FILE=$(find . -name "*.clusterserviceversion.yaml" | head -1)
    if [[ -n "${CSV_FILE}" ]]; then
        echo "Found CSV file: ${CSV_FILE}"
        
        # Extract the exact 3 images from CSV that need mirroring.
        OPERATOR_IMAGE_FROM_CSV=$(yq '.spec.install.spec.deployments[].spec.template.spec.containers[].image' "${CSV_FILE}")
        OPERAND_IMAGE_FROM_CSV=$(yq '.spec.install.spec.deployments[].spec.template.spec.containers[].env[] | select(.name == "RELATED_IMAGE_OPERAND_IMAGE") | .value' "${CSV_FILE}")
        MUST_GATHER_IMAGE_FROM_CSV=$(yq '.spec.relatedImages[] | select(.name == "must-gather") | .image' "${CSV_FILE}")
        
        echo "Extracted CSV image references:"
        echo "  - Operator: ${OPERATOR_IMAGE_FROM_CSV}"
        echo "  - Operand: ${OPERAND_IMAGE_FROM_CSV}"
        echo "  - Must-gather: ${MUST_GATHER_IMAGE_FROM_CSV}"
        
        echo "export OPERATOR_IMAGE_FROM_CSV=${OPERATOR_IMAGE_FROM_CSV}" >> "${SHARED_DIR}/env"
        echo "export OPERAND_IMAGE_FROM_CSV=${OPERAND_IMAGE_FROM_CSV}" >> "${SHARED_DIR}/env"
        echo "export MUST_GATHER_IMAGE_FROM_CSV=${MUST_GATHER_IMAGE_FROM_CSV}" >> "${SHARED_DIR}/env"
        
        echo "CSV image references exported to env file"
    else
        echo "WARNING: No CSV file found in bundle"
    fi
else
    echo "ERROR: No layer file found for extraction"
fi

# Clean up
rm -rf "${TEMP_BUNDLE_DIR}"
