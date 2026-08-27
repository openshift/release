#!/bin/bash
set -euo pipefail

# Standalone script to fetch the latest bootc image tag from Quay.io
# Usage: ./hack/get-latest-bootc-tag.sh [IMAGE_BASE]
#
# Examples:
#   ./hack/get-latest-bootc-tag.sh quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc
#   ./hack/get-latest-bootc-tag.sh quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-102-bootc

IMAGE_BASE="${1:-quay.io/redhat-user-workloads/jetpack-for-rhel-tenant/rhel-98-bootc}"

# Extract the path after quay.io/
IMAGE_PATH="${IMAGE_BASE#quay.io/}"

echo "Querying latest tag for: ${IMAGE_BASE}" >&2

# Query Quay API with pagination
QUAY_API_BASE="https://quay.io/api/v1/repository/${IMAGE_PATH}/tag/?onlyActiveTags=true&limit=100"

# Fetch all tags with pagination support
ALL_TAGS="[]"
PAGE=1
MAX_PAGES=10  # Safety limit

while [[ ${PAGE} -le ${MAX_PAGES} ]]; do
  QUAY_API_URL="${QUAY_API_BASE}&page=${PAGE}"

  RESPONSE=$(curl --silent --fail "${QUAY_API_URL}" 2>/dev/null || true)
  if [[ -z "${RESPONSE}" ]]; then
    break
  fi

  PAGE_TAGS=$(echo "${RESPONSE}" | jq -r '.tags // []')
  HAS_ADDITIONAL=$(echo "${RESPONSE}" | jq -r '.has_additional // false')

  ALL_TAGS=$(echo "${ALL_TAGS}" "${PAGE_TAGS}" | jq -s 'add')

  if [[ "${HAS_ADDITIONAL}" != "true" ]]; then
    break
  fi

  PAGE=$((PAGE + 1))
done

# Filter out metadata tags and sort by last_modified
LATEST_TAG=$(echo "${ALL_TAGS}" | \
  jq -r 'map(select(.name | test("\\.(att|sig|sbom|src|dockerfile)$") | not)) | sort_by(.last_modified) | reverse | .[0].name')

if [[ -z "${LATEST_TAG}" || "${LATEST_TAG}" == "null" ]]; then
  echo "ERROR: Failed to fetch latest tag from Quay API" >&2
  exit 1
fi

echo "Latest tag: ${LATEST_TAG}" >&2
echo "${IMAGE_BASE}:${LATEST_TAG}"
