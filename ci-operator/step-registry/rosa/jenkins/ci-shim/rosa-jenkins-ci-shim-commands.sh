#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ============================================================================
# ROSA GovCloud CI Shim
# ============================================================================
# Polls S3 for test results from GovCloud reconciler and reports to Prow.
#
# Design: https://gist.github.com/ironcladlou/3fcefa62000e2a07017ee846b568937b
# ============================================================================

# Configuration
POLL_INTERVAL="${GOVCLOUD_POLL_INTERVAL:-30}"
TIMEOUT="${GOVCLOUD_TIMEOUT:-7200}"
JENKINS_JOB="${GOVCLOUD_JENKINS_JOB:-unknown}"

# Validate required environment
if [[ -z "${PROW_JOB_ID:-}" ]]; then
    echo "ERROR: PROW_JOB_ID environment variable is required"
    echo "This variable is automatically set by Prow decoration"
    exit 1
fi

if [[ -z "${ARTIFACT_DIR:-}" ]]; then
    echo "ERROR: ARTIFACT_DIR environment variable is required"
    echo "This variable is automatically set by Prow decoration"
    exit 1
fi

# Log function with timestamp
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

log_error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2
}

log_success() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ✓ $*"
}

# ============================================================================
# AWS Configuration
# ============================================================================

log "Configuring AWS credentials..."

AWSCRED="/tmp/s3-creds/.awscred"
if [[ ! -f "${AWSCRED}" ]]; then
    log_error "AWS credentials file not found at ${AWSCRED}"
    log_error "Expected secret 'rosa-govcloud-s3-creds' mounted at /tmp/s3-creds"
    exit 1
fi

export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
export AWS_DEFAULT_REGION="${S3_REGION}"

# Verify AWS CLI is available
if ! command -v aws &> /dev/null; then
    log_error "aws CLI not found in PATH"
    exit 1
fi

log_success "AWS configured for region: ${S3_REGION}"

# ============================================================================
# S3 Path Configuration
# ============================================================================

S3_BASE_PATH="s3://${S3_BUCKET}/${PROW_JOB_ID}"
S3_RESULT_FILE="${S3_BASE_PATH}/result.json"
S3_ARTIFACTS_PREFIX="${S3_BASE_PATH}/artifacts/"

log "Prow Job ID: ${PROW_JOB_ID}"
log "Jenkins Job: ${JENKINS_JOB}"
log "S3 Result Path: ${S3_RESULT_FILE}"
log "S3 Artifacts Path: ${S3_ARTIFACTS_PREFIX}"
log "Poll Interval: ${POLL_INTERVAL}s"
log "Timeout: ${TIMEOUT}s ($(( TIMEOUT / 60 )) minutes)"

# ============================================================================
# Helper Functions
# ============================================================================

# Check if result.json exists in S3
check_result_exists() {
    aws s3 ls "${S3_RESULT_FILE}" >/dev/null 2>&1
}

# Download result.json
download_result() {
    local result_path="$1"
    if ! aws s3 cp "${S3_RESULT_FILE}" "${result_path}"; then
        log_error "Failed to download result.json from S3"
        return 1
    fi
    return 0
}

# Download all artifacts from S3 to ARTIFACT_DIR
download_artifacts() {
    log "Downloading artifacts from S3..."

    # Check if artifacts directory exists in S3
    if ! aws s3 ls "${S3_ARTIFACTS_PREFIX}" >/dev/null 2>&1; then
        log "No artifacts directory found in S3 (this may be expected)"
        return 0
    fi

    # Create artifacts subdirectory in ARTIFACT_DIR
    local artifact_dest="${ARTIFACT_DIR}/govcloud-artifacts"
    mkdir -p "${artifact_dest}"

    # Download all artifacts recursively
    if aws s3 sync "${S3_ARTIFACTS_PREFIX}" "${artifact_dest}" --quiet; then
        log_success "Artifacts downloaded to ${artifact_dest}"

        # List what we downloaded for transparency
        log "Downloaded files:"
        find "${artifact_dest}" -type f -exec basename {} \; | while read -r file; do
            log "  - ${file}"
        done

        return 0
    else
        log_error "Failed to download artifacts from S3"
        return 1
    fi
}

# Parse result.json and determine exit status
parse_result() {
    local result_file="$1"

    if [[ ! -f "${result_file}" ]]; then
        log_error "Result file not found: ${result_file}"
        return 1
    fi

    log "Parsing result.json..."

    # Validate JSON
    if ! jq empty "${result_file}" 2>/dev/null; then
        log_error "Invalid JSON in result.json"
        cat "${result_file}"
        return 1
    fi

    # Extract fields
    local status=$(jq -r '.status // "unknown"' "${result_file}")
    local duration=$(jq -r '.duration // "unknown"' "${result_file}")
    local jenkins_build=$(jq -r '.jenkinsBuild // "unknown"' "${result_file}")
    local message=$(jq -r '.message // ""' "${result_file}")

    log "========================================"
    log "GovCloud Test Results"
    log "========================================"
    log "Status: ${status}"
    log "Duration: ${duration}"
    log "Jenkins Build: ${jenkins_build}"
    if [[ -n "${message}" ]]; then
        log "Message: ${message}"
    fi
    log "========================================"

    # Copy result.json to ARTIFACT_DIR for Prow visibility
    cp "${result_file}" "${ARTIFACT_DIR}/result.json"

    # Determine exit code based on status
    case "${status}" in
        success)
            log_success "GovCloud test execution successful"
            return 0
            ;;
        failure)
            log_error "GovCloud test execution failed"
            return 1
            ;;
        error)
            log_error "GovCloud test execution encountered an error"
            return 1
            ;;
        *)
            log_error "Unknown status: ${status}"
            return 1
            ;;
    esac
}

# ============================================================================
# Main Polling Loop
# ============================================================================

log "========================================"
log "Starting GovCloud CI Shim"
log "========================================"

START_TIME=$(date +%s)
POLL_COUNT=0

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$(( CURRENT_TIME - START_TIME ))
    POLL_COUNT=$(( POLL_COUNT + 1 ))

    # Check timeout
    if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
        log_error "Timeout reached after ${ELAPSED}s (${POLL_COUNT} polls)"
        log_error "No results received from GovCloud reconciler"
        log_error "Expected result at: ${S3_RESULT_FILE}"

        # Create timeout marker for debugging
        cat > "${ARTIFACT_DIR}/timeout.json" <<EOF
{
  "error": "timeout",
  "elapsed_seconds": ${ELAPSED},
  "timeout_seconds": ${TIMEOUT},
  "poll_count": ${POLL_COUNT},
  "expected_result_path": "${S3_RESULT_FILE}",
  "prow_job_id": "${PROW_JOB_ID}",
  "jenkins_job": "${JENKINS_JOB}"
}
EOF

        exit 1
    fi

    # Log progress every 10 polls
    if (( POLL_COUNT % 10 == 0 )); then
        REMAINING=$(( TIMEOUT - ELAPSED ))
        log "Poll #${POLL_COUNT}: Still waiting... (${ELAPSED}s elapsed, ${REMAINING}s remaining)"
    fi

    # Check if result.json exists
    if check_result_exists; then
        log_success "Result file detected after ${ELAPSED}s (${POLL_COUNT} polls)"

        # Download result.json
        RESULT_FILE="/tmp/result.json"
        if ! download_result "${RESULT_FILE}"; then
            log_error "Failed to download result.json"
            exit 1
        fi

        # Download artifacts
        if ! download_artifacts; then
            log_error "Failed to download artifacts (continuing anyway)"
        fi

        # Parse result and exit with appropriate code
        if parse_result "${RESULT_FILE}"; then
            log_success "Shim completed successfully"
            exit 0
        else
            log_error "Shim completed with failure"
            exit 1
        fi
    fi

    # Wait before next poll
    sleep "${POLL_INTERVAL}"
done
