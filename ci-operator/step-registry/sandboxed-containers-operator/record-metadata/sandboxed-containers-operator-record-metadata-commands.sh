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

    # Get build time using Quay.io API (faster than skopeo inspect)
    # Parse image path: quay.io/namespace/repo:tag -> namespace/repo
    IMAGE_PATH="${CATALOG_SOURCE_IMAGE#quay.io/}"
    IMAGE_PATH="${IMAGE_PATH%:*}"

    # Query Quay API for tag info - returns start_ts (Unix timestamp)
    BUILD_TIME=$(curl -sf "https://quay.io/api/v1/repository/${IMAGE_PATH}/tag/?specificTag=${CATALOG_TAG}" 2>/dev/null | \
        jq -r '.tags[0].start_ts // empty' 2>/dev/null || echo "")

    # Convert Unix timestamp to ISO 8601 format
    if [[ -n "${BUILD_TIME}" && "${BUILD_TIME}" != "null" ]]; then
        BUILD_TIME=$(date -u -d "@${BUILD_TIME}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "${BUILD_TIME}")
    else
        BUILD_TIME="unknown"
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
timestamp,catalog_tag,build_time,prow_job_url,cloud_provider,ocp_version,workload_to_test,kata_rpm_version
${TIMESTAMP},${CATALOG_TAG},${BUILD_TIME},${PROW_JOB_URL},${CLOUD_PROVIDER},${OCP_VERSION},${WORKLOAD_TO_TEST:-kata},${KATA_RPM_VERSION:-}
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
echo "Prow Job URL:         ${PROW_JOB_URL:-N/A}"
echo "Cloud Provider:       ${CLOUD_PROVIDER}"
echo "OCP Version:          ${OCP_VERSION}"
echo "Workload To Test:     ${WORKLOAD_TO_TEST:-kata}"
echo "Kata RPM Version:     ${KATA_RPM_VERSION:-N/A}"
echo "=========================================="
echo ""
echo "CSV line (copy to spreadsheet):"
echo "${TIMESTAMP},${CATALOG_TAG},${BUILD_TIME},${PROW_JOB_URL},${CLOUD_PROVIDER},${OCP_VERSION},${WORKLOAD_TO_TEST:-kata},${KATA_RPM_VERSION:-}"
