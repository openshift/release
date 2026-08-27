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

# Query Quay API for the most recent tag with pagination
# API docs: https://docs.quay.io/api/swagger/#!/tag/listRepoTags
QUAY_API_BASE="https://quay.io/api/v1/repository/${IMAGE_PATH}/tag/?onlyActiveTags=true&limit=100"

echo "Querying Quay API with pagination..."

# Fetch all tags with pagination support
ALL_TAGS="[]"
PAGE=1
MAX_PAGES=10  # Safety limit to prevent infinite loops

while [[ ${PAGE} -le ${MAX_PAGES} ]]; do
  QUAY_API_URL="${QUAY_API_BASE}&page=${PAGE}"

  RESPONSE=$(curl --silent --fail "${QUAY_API_URL}" || true)
  if [[ -z "${RESPONSE}" ]]; then
    echo "Failed to fetch page ${PAGE}, stopping pagination"
    break
  fi

  PAGE_TAGS=$(echo "${RESPONSE}" | jq -r '.tags // []')
  HAS_ADDITIONAL=$(echo "${RESPONSE}" | jq -r '.has_additional // false')

  # Merge this page's tags with all collected tags
  ALL_TAGS=$(echo "${ALL_TAGS}" "${PAGE_TAGS}" | jq -s 'add')

  echo "Fetched page ${PAGE}, tags count: $(echo "${PAGE_TAGS}" | jq 'length')"

  if [[ "${HAS_ADDITIONAL}" != "true" ]]; then
    echo "No more pages to fetch"
    break
  fi

  PAGE=$((PAGE + 1))
done

# Filter out metadata tags (.att, .sig, .sbom, .src, .dockerfile) and sort by last_modified
LATEST_TAG=$(echo "${ALL_TAGS}" | \
  jq -r 'map(select(.name | test("\\.(att|sig|sbom|src|dockerfile)$") | not)) | sort_by(.last_modified) | reverse | .[0].name')

if [[ -z "${LATEST_TAG}" || "${LATEST_TAG}" == "null" ]]; then
  echo "ERROR: Failed to fetch latest tag from Quay API"
  echo "Total tags fetched: $(echo "${ALL_TAGS}" | jq 'length')"
  echo "Response sample:"
  echo "${ALL_TAGS}" | jq '.[0:3]'
  exit 1
fi

echo "Latest tag found: ${LATEST_TAG}"
echo "Full image: ${BOOTC_IMAGE_BASE}:${LATEST_TAG}"

# Export for use in subsequent steps
echo "${BOOTC_IMAGE_BASE}:${LATEST_TAG}" > "${SHARED_DIR}/bootc_image_url"
echo "${LATEST_TAG}" > "${SHARED_DIR}/bootc_image_tag"

echo "=== Saved to SHARED_DIR for use by subsequent steps ==="
