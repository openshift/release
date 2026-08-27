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

# Query Quay API
QUAY_API_URL="https://quay.io/api/v1/repository/${IMAGE_PATH}/tag/?onlyActiveTags=true&limit=10"

# Fetch tags and sort by last_modified to get the truly latest
# Filter out metadata tags (.att, .sig, .sbom, .src, .dockerfile)
# Prefer version tags matching pattern: X.Y.Z_kernel_datestamp or datestamp
LATEST_TAG=$(curl --silent --fail "${QUAY_API_URL}" | \
  jq -r '.tags | map(select(.name | test("\\.(att|sig|sbom|src|dockerfile)$") | not)) | sort_by(.last_modified) | reverse | .[0].name')

if [[ -z "${LATEST_TAG}" || "${LATEST_TAG}" == "null" ]]; then
  echo "ERROR: Failed to fetch latest tag from Quay API" >&2
  echo "API URL: ${QUAY_API_URL}" >&2
  exit 1
fi

echo "Latest tag: ${LATEST_TAG}" >&2
echo "${IMAGE_BASE}:${LATEST_TAG}"
