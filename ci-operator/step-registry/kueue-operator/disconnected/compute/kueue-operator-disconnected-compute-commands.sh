#!/usr/bin/env bash

set -e
set -u
set -o pipefail

# Resolve the newest 40-char SHA tag of a Quay repo via the Quay tag API.
# Reads push timestamps (start_ts) in bulk instead of running `skopeo inspect`
# per tag, which does not scale with the number of accumulated CI build tags.
# Prints "<repo>:<sha>" for the newest tag, or nothing if none is found.
resolve_latest_image() {
  local repo=$1
  local api_repo="${repo#quay.io/}"
  local page=1 resp attempt latest=""
  # Quay returns tags newest-first, so page 1 normally already holds the newest
  # SHA-form tag; keep paging only while Quay reports additional pages.
  while :; do
    resp=""
    for attempt in 1 2 3; do
      if resp=$(wget -q -O - --tries=1 --timeout=30 \
          "https://quay.io/api/v1/repository/${api_repo}/tag/?onlyActiveTags=true&limit=100&page=${page}"); then
        break
      fi
      echo "WARN: Quay tag API call failed for ${api_repo} (page ${page}, attempt ${attempt}); retrying..." >&2
      resp=""
      sleep $((attempt * 3))
    done
    [ -n "$resp" ] || { echo "ERROR: Quay tag API unreachable for ${api_repo} after retries" >&2; return 1; }
    latest=$(echo "$resp" | jq -r '
      [.tags[]? | select(.name | test("^[a-f0-9]{40}$"))]
      | sort_by(.start_ts) | reverse | .[0].name // empty')
    [ -n "$latest" ] && break
    [ "$(echo "$resp" | jq -r '.has_additional')" = "true" ] || break
    page=$((page + 1))
    if [ "$page" -gt 100 ]; then
      echo "ERROR: no SHA-form tag found for ${api_repo} within ${page} pages" >&2
      return 1
    fi
  done
  if [ -z "$latest" ]; then
    echo "ERROR: no SHA-form tag found for ${api_repo}" >&2
    return 1
  fi
  echo "${repo}:${latest}"
}

echo "[$(date -u --rfc-3339=seconds)] Resolving latest bundle image..."
BUNDLE_REPO="quay.io/redhat-user-workloads/kueue-operator-tenant/${BUNDLE_COMPONENT}"
BUNDLE_IMAGE=$(resolve_latest_image "$BUNDLE_REPO")

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
