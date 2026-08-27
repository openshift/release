#!/bin/bash
set -euo pipefail

# Fetch the actual latest tag from Quay for a bootc image
# This is necessary because the :latest tag isn't always updated automatically

BOOTC_IMAGE_BASE="${BOOTC_IMAGE_BASE:-quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc}"

# Extract namespace and repo from the image base
# Format: quay.io/namespace/repo or quay.io/org/namespace/repo
IMAGE_PATH="${BOOTC_IMAGE_BASE#quay.io/}"
# For redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc:
# This becomes: redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc

echo "=== Fetching latest tag for ${BOOTC_IMAGE_BASE} ==="

# Query Quay API for the most recent tag
# API docs: https://docs.quay.io/api/swagger/#!/tag/listRepoTags
QUAY_API_URL="https://quay.io/api/v1/repository/${IMAGE_PATH}/tag/?onlyActiveTags=true&limit=10"

echo "Querying: ${QUAY_API_URL}"

# Fetch tags and sort by last_modified to get the truly latest
# Filter out metadata tags (.att, .sig, .sbom, .src, .dockerfile)
# Prefer version tags matching pattern: X.Y.Z_kernel_datestamp or datestamp
LATEST_TAG=$(curl --silent --fail "${QUAY_API_URL}" | \
  jq -r '.tags | map(select(.name | test("\\.(att|sig|sbom|src|dockerfile)$") | not)) | sort_by(.last_modified) | reverse | .[0].name')

if [[ -z "${LATEST_TAG}" || "${LATEST_TAG}" == "null" ]]; then
  echo "ERROR: Failed to fetch latest tag from Quay API"
  echo "Response was:"
  curl --silent "${QUAY_API_URL}" | jq '.'
  exit 1
fi

echo "Latest tag found: ${LATEST_TAG}"
echo "Full image: ${BOOTC_IMAGE_BASE}:${LATEST_TAG}"

# Export for use in subsequent steps
echo "${BOOTC_IMAGE_BASE}:${LATEST_TAG}" > "${SHARED_DIR}/bootc_image_url"
echo "${LATEST_TAG}" > "${SHARED_DIR}/bootc_image_tag"

echo "=== Saved to SHARED_DIR for use by subsequent steps ==="
