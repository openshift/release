#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=========================================="
echo "Sandboxed Containers Operator - Record Test Metadata"
echo "=========================================="

# Generate timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Extract tag and build time from CATALOG_SOURCE_IMAGE
# Example: quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc:1.10.0-1
if [[ -n "${CATALOG_SOURCE_IMAGE:-}" ]]; then
    CATALOG_TAG="${CATALOG_SOURCE_IMAGE##*:}"

    # Check if curl is available
    if ! command -v curl &>/dev/null; then
        BUILD_TIME="unknown"
        echo "WARNING: curl is not available, cannot query Quay API for build time" | tee -a "${ARTIFACT_DIR}/build-log.txt"
    else
        # Get build time using Quay.io API
        # Parse image path: quay.io/namespace/repo:tag -> namespace/repo
        IMAGE_PATH="${CATALOG_SOURCE_IMAGE#quay.io/}"
        IMAGE_PATH="${IMAGE_PATH%:*}"

        # Search through tag pages to find the matching tag and get last_modified
        BUILD_TIME=""
        for page in 1 2 3 4 5; do
            API_OUTPUT=$(curl -sf "https://quay.io/api/v1/repository/${IMAGE_PATH}/tag/?limit=100&page=${page}" 2>&1) || true
            if [[ -z "${API_OUTPUT}" ]]; then
                break
            fi

            # Find the tag and get its last_modified timestamp
            BUILD_TIME=$(echo "${API_OUTPUT}" | jq -r --arg tag "${CATALOG_TAG}" \
                '.tags[] | select(.name == $tag) | .last_modified // empty' 2>/dev/null || echo "")

            if [[ -n "${BUILD_TIME}" ]]; then
                break
            fi

            # Check if there are more pages
            HAS_MORE=$(echo "${API_OUTPUT}" | jq -r '.has_additional // false' 2>/dev/null)
            if [[ "${HAS_MORE}" != "true" ]]; then
                break
            fi
        done

        if [[ -z "${BUILD_TIME}" ]]; then
            BUILD_TIME="unknown"
            echo "WARNING: Failed to get build time for image" | tee -a "${ARTIFACT_DIR}/build-log.txt"
            echo "  CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE}" | tee -a "${ARTIFACT_DIR}/build-log.txt"
            echo "  CATALOG_TAG: ${CATALOG_TAG}" | tee -a "${ARTIFACT_DIR}/build-log.txt"
            echo "  IMAGE_PATH: ${IMAGE_PATH}" | tee -a "${ARTIFACT_DIR}/build-log.txt"
        fi
    fi
else
    CATALOG_TAG=""
    BUILD_TIME=""
fi

# Build Prow job URL
# PROW_JOB_ID and JOB_NAME are provided by Prow
PROW_JOB_URL=""
if [[ -n "${PROW_JOB_ID:-}" ]]; then
    PROW_JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME:-unknown}/${BUILD_ID:-unknown}"
fi

# Get cloud provider from CLUSTER_TYPE
# CLUSTER_TYPE is set by the workflow based on cluster_profile
CLOUD_PROVIDER="${CLUSTER_TYPE:-unknown}"

# Get OCP version from the cluster
OCP_VERSION=""
if [[ -f "${KUBECONFIG:-}" ]]; then
    OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
else
    OCP_VERSION="unknown (no kubeconfig)"
fi

# Create CSV metadata file (easily copied into spreadsheet)
CSV_FILE="${ARTIFACT_DIR}/test-metadata.csv"

# Write CSV header and data
cat > "${CSV_FILE}" <<EOF
timestamp,catalog_tag,build_time,cloud_provider,ocp_version,prow_job_url,workload_to_test,kata_rpm_version
${TIMESTAMP},${CATALOG_TAG},${BUILD_TIME},${CLOUD_PROVIDER},${OCP_VERSION},${PROW_JOB_URL},${WORKLOAD_TO_TEST:-kata},${KATA_RPM_VERSION:-}
EOF

echo "Test metadata recorded to ${CSV_FILE}:"
cat "${CSV_FILE}"

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
echo "CSV line (copy to spreadsheet):"
echo "${TIMESTAMP},${CATALOG_TAG},${BUILD_TIME},${CLOUD_PROVIDER},${OCP_VERSION},${PROW_JOB_URL},${WORKLOAD_TO_TEST:-kata},${KATA_RPM_VERSION:-}"
