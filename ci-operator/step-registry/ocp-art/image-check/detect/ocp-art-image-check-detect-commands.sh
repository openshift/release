#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== OCP ART Image Check ==="
echo "Scanning all image definition files in the images directory..."

# Install yq if not available
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.35.2"
    YQ_BINARY="yq_linux_amd64"
    curl -L "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -o /tmp/yq
    chmod +x /tmp/yq
    export PATH="/tmp:${PATH}"
fi

# Find all YAML files in the images directory
IMAGE_FILES=$(find images/ -name '*.yml' -o -name '*.yaml' 2>/dev/null || true)

if [ -z "${IMAGE_FILES}" ]; then
    echo "⚠️  No YAML files found in images/ directory"
    exit 0
fi

echo "🔍 Scanning the following image definition files:"
echo "${IMAGE_FILES}"
echo ""

# Process each file
while IFS= read -r file; do
    if [ -n "$file" ] && [ -f "${file}" ]; then
        # Extract delivery_repo_names using yq
        DELIVERY_REPOS=$(yq eval '.delivery.delivery_repo_names[]?' "${file}" 2>/dev/null || echo "")
        if [ -n "${DELIVERY_REPOS}" ]; then
            echo "📄 File: ${file}"
            echo "delivery_repo_names:"
            echo "${DELIVERY_REPOS}" | while read -r repo; do
                if [ -n "${repo}" ]; then
                    echo "  - ${repo}"
                fi
            done
            echo ""
        fi
    fi
done <<< "${IMAGE_FILES}"

echo "=== Image Check Complete ==="