#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# Verify ARTIFACT_DIR is set and exists
if [[ -z "${ARTIFACT_DIR:-}" ]]; then
    echo "ERROR: ARTIFACT_DIR is not set"
    exit 1
fi

if [[ ! -d "${ARTIFACT_DIR}" ]]; then
    echo "WARNING: ARTIFACT_DIR does not exist, creating: ${ARTIFACT_DIR}"
    mkdir -p "${ARTIFACT_DIR}"
fi

# Log file for debugging
LOG_FILE="${ARTIFACT_DIR}/build-log.txt"
echo "Starting record-metadata step at $(date -u)" | tee "${LOG_FILE}"

# Check for required tools
echo "Checking required tools..." | tee -a "${LOG_FILE}"
for tool in curl oc; do
    if command -v "${tool}" &>/dev/null; then
        echo "  ${tool}: available" | tee -a "${LOG_FILE}"
    else
        echo "  ${tool}: NOT FOUND" | tee -a "${LOG_FILE}"
    fi
done

# Log environment variables (for debugging)
echo "" | tee -a "${LOG_FILE}"
echo "Environment variables:" | tee -a "${LOG_FILE}"
echo "  CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE:-<not set>}" | tee -a "${LOG_FILE}"
echo "  WORKLOAD_TO_TEST: ${WORKLOAD_TO_TEST:-<not set>}" | tee -a "${LOG_FILE}"
echo "  KATA_RPM_VERSION: ${KATA_RPM_VERSION:-<not set>}" | tee -a "${LOG_FILE}"
echo "  CLUSTER_TYPE: ${CLUSTER_TYPE:-<not set>}" | tee -a "${LOG_FILE}"
echo "  KUBECONFIG: ${KUBECONFIG:-<not set>}" | tee -a "${LOG_FILE}"
echo "  PROW_JOB_ID: ${PROW_JOB_ID:-<not set>}" | tee -a "${LOG_FILE}"
echo "  JOB_NAME: ${JOB_NAME:-<not set>}" | tee -a "${LOG_FILE}"
echo "  BUILD_ID: ${BUILD_ID:-<not set>}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# Generate timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Extract tag and build time from CATALOG_SOURCE_IMAGE
# Supports multiple formats:
#   - Regular tag: quay.io/namespace/repo:tag
#   - SHA digest:  quay.io/namespace/repo@sha256:abc123...
#   - SHA tag:     quay.io/namespace/repo:sha256-abc123...
if [[ -n "${CATALOG_SOURCE_IMAGE:-}" ]]; then
    # Determine if this is a digest reference (@sha256:) or a tag reference (:)
    if [[ "${CATALOG_SOURCE_IMAGE}" == *"@sha256:"* ]]; then
        # Digest reference: quay.io/namespace/repo@sha256:abc123...
        CATALOG_TAG="${CATALOG_SOURCE_IMAGE##*@}"
        IMAGE_PATH="${CATALOG_SOURCE_IMAGE#quay.io/}"
        IMAGE_PATH="${IMAGE_PATH%@*}"
        SEARCH_FIELD="manifest_digest"
        SEARCH_VALUE="sha256:${CATALOG_TAG#sha256:}"
        echo "Detected SHA digest reference: ${SEARCH_VALUE}" | tee -a "${LOG_FILE}"
    else
        # Tag reference: quay.io/namespace/repo:tag
        CATALOG_TAG="${CATALOG_SOURCE_IMAGE##*:}"
        IMAGE_PATH="${CATALOG_SOURCE_IMAGE#quay.io/}"
        IMAGE_PATH="${IMAGE_PATH%:*}"
        SEARCH_FIELD="name"
        SEARCH_VALUE="${CATALOG_TAG}"
        echo "Detected tag reference: ${SEARCH_VALUE}" | tee -a "${LOG_FILE}"
    fi

    # Check if curl is available
    if ! command -v curl &>/dev/null; then
        BUILD_TIME="cannot be found"
        echo "WARNING: curl is not available, cannot query Quay API for build time" | tee -a "${LOG_FILE}"
    else
        # Get build time using Quay.io API
        # Search through tag pages to find the matching tag/digest and get last_modified
        # Using grep/sed instead of jq for parsing JSON
        BUILD_TIME=""
        for page in 1 2 3 4 5; do
            API_OUTPUT=$(curl -sf "https://quay.io/api/v1/repository/${IMAGE_PATH}/tag/?limit=100&page=${page}" 2>&1) || true
            if [[ -z "${API_OUTPUT}" ]]; then
                break
            fi

            # Find the tag entry and extract last_modified using grep/sed
            # The JSON format is: {"name": "tag", "manifest_digest": "sha256:...", "last_modified": "Mon, 19 Jan 2026 13:19:23 -0000", ...}
            # We search for the tag name or manifest_digest and then extract the last_modified from that entry
            if echo "${API_OUTPUT}" | grep -q "\"${SEARCH_FIELD}\": *\"${SEARCH_VALUE}\""; then
                # Extract the JSON object containing this tag/digest and get last_modified
                # This uses sed to find the section with our tag and extract last_modified
                RAW_BUILD_TIME=$(echo "${API_OUTPUT}" | \
                    grep -o "{[^}]*\"${SEARCH_FIELD}\": *\"${SEARCH_VALUE}\"[^}]*}" | \
                    head -1 | \
                    sed -n 's/.*"last_modified": *"\([^"]*\)".*/\1/p')
                if [[ -n "${RAW_BUILD_TIME}" ]]; then
                    # Convert from "Mon, 19 Jan 2026 13:19:23 -0000" to ISO 8601 format
                    BUILD_TIME=$(date -u -d "${RAW_BUILD_TIME}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "${RAW_BUILD_TIME}")
                    break
                fi
            fi

            # Check if there are more pages
            if ! echo "${API_OUTPUT}" | grep -q '"has_additional": *true'; then
                break
            fi
        done

        if [[ -z "${BUILD_TIME}" ]]; then
            BUILD_TIME="cannot be found"
            echo "WARNING: Failed to get build time for image" | tee -a "${LOG_FILE}"
            echo "  CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE}" | tee -a "${LOG_FILE}"
            echo "  CATALOG_TAG: ${CATALOG_TAG}" | tee -a "${LOG_FILE}"
            echo "  IMAGE_PATH: ${IMAGE_PATH}" | tee -a "${LOG_FILE}"
            echo "  SEARCH_FIELD: ${SEARCH_FIELD}" | tee -a "${LOG_FILE}"
            echo "  SEARCH_VALUE: ${SEARCH_VALUE}" | tee -a "${LOG_FILE}"
        fi
    fi
else
    CATALOG_TAG="image not set"
    BUILD_TIME="cannot be found"
fi

# PROW_JOB_ID and JOB_NAME are provided by Prow
PROW_JOB_URL=""
if [[ -n "${PROW_JOB_ID:-}" ]]; then
    PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME:-unknown}/${BUILD_ID:-unknown}"
fi

# CLUSTER_TYPE is set by the workflow based on cluster_profile
CLOUD_PROVIDER="${CLUSTER_TYPE:-unknown}"

OCP_VERSION=""
if [[ -f "${KUBECONFIG:-}" ]]; then
    OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "cannot be found")
else
    OCP_VERSION="cannot be found (no kubeconfig)"
fi

# Create CSV metadata file (easily copied into spreadsheet)
CSV_FILE="${ARTIFACT_DIR}/test-metadata.csv"

# Write CSV header and data
cat > "${CSV_FILE}" <<EOF
timestamp,catalog_tag,build_time,cloud_provider,ocp_version,prow_job_url,workload_to_test,kata_rpm_version
${TIMESTAMP},${CATALOG_TAG},${BUILD_TIME},${CLOUD_PROVIDER},${OCP_VERSION},${PROW_JOB_URL},${WORKLOAD_TO_TEST:-kata},${KATA_RPM_VERSION:-}
EOF

echo ""
echo "=========================================="
echo "Test Metadata Summary"
echo "=========================================="
echo "Timestamp:            ${TIMESTAMP}"
echo "Catalog Tag:          ${CATALOG_TAG:-N/A}"
echo "Build Time:           ${BUILD_TIME:-N/A}"
echo "Cloud Provider:       ${CLOUD_PROVIDER}"
echo "OCP Version:          ${OCP_VERSION}"
echo "Prow Job URL:         ${PROW_JOB_URL:-N/A}"
echo "Workload To Test:     ${WORKLOAD_TO_TEST:-kata}"
echo "Kata RPM Version:     ${KATA_RPM_VERSION:-N/A}"
echo "=========================================="
echo ""

echo "Test metadata recorded to ${CSV_FILE}:"
cat "${CSV_FILE}"
