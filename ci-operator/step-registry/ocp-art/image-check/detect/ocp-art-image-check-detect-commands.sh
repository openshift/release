#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== OCP ART Image Check ==="
echo "Checking for changes to image definition files in the images directory..."

# Install yq if not available
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    YQ_VERSION="v4.35.2"
    YQ_BINARY="yq_linux_amd64"
    curl -L "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -o /tmp/yq
    chmod +x /tmp/yq
    export PATH="/tmp:${PATH}"
fi

# Get the base commit to compare against
# For PRs, this should be the target branch HEAD
BASE_SHA=$(git merge-base HEAD origin/$(git rev-parse --abbrev-ref HEAD))

echo "Comparing against base commit: ${BASE_SHA}"

# Find all changed files in the images directory
CHANGED_IMAGE_FILES=$(git diff --name-only ${BASE_SHA}...HEAD | grep '^images/' | grep '\.ya*ml$' || true)

if [ -z "${CHANGED_IMAGE_FILES}" ]; then
    echo "ℹ️  No image definition files have been changed in this PR."
    echo "📄 Picking the first YAML file under images/ to run the test..."
    FIRST_IMAGE_FILE=$(find images/ -name '*.yml' -o -name '*.yaml' | head -1 || true)
    if [ -n "${FIRST_IMAGE_FILE}" ]; then
        CHANGED_IMAGE_FILES="${FIRST_IMAGE_FILE}"
        echo "Selected file: ${FIRST_IMAGE_FILE}"
    else
        echo "⚠️  No YAML files found in images/ directory"
        exit 0
    fi
fi

echo "🔍 Found changes to the following image definition files:"
echo "${CHANGED_IMAGE_FILES}"
echo ""

# Process each changed file
while IFS= read -r file; do
    if [ -n "$file" ]; then
        echo "📄 Processing file: ${file}"
        if [ -f "${file}" ]; then
            # Extract delivery_repos_names using yq
            DELIVERY_REPOS=$(yq eval '.delivery_repos_names[]?' "${file}" 2>/dev/null || echo "")
            if [ -n "${DELIVERY_REPOS}" ]; then
                echo "delivery_repos_names:"
                echo "${DELIVERY_REPOS}" | while read -r repo; do
                    if [ -n "${repo}" ]; then
                        echo "  - ${repo}"
                    fi
                done
            else
                echo "⚠️  No delivery_repos_names found in ${file}"
            fi
        else
            echo "⚠️  File ${file} has been deleted"
        fi
        echo ""
    fi
done <<< "${CHANGED_IMAGE_FILES}"

echo "=== Image Check Complete ==="