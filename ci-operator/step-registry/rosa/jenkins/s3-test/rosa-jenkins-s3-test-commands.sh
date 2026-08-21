#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Log function
log() {
    echo -e "\033[1m$(date "+%Y-%m-%dT%H:%M:%S") " "${*}\033[0m"
}

log "Starting ROSA GovCloud S3 integration test..."

# Configure AWS credentials
AWSCRED="/tmp/s3-creds/.awscred"
if [[ ! -f "${AWSCRED}" ]]; then
  log "ERROR: AWS credentials file not found at ${AWSCRED}"
  log "Expected secret 'rosa-govcloud-s3-creds' to be mounted at /tmp/s3-creds"
  exit 1
fi

export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
export AWS_DEFAULT_REGION="${S3_REGION}"

log "AWS credentials configured for region: ${S3_REGION}"

# Verify AWS CLI is available
if ! command -v aws &> /dev/null; then
    log "ERROR: aws CLI not found in PATH"
    exit 1
fi

# Generate test trigger metadata
TRIGGER_ID="test-$(date +%s)-${BUILD_ID:-local}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log "Creating test trigger with ID: ${TRIGGER_ID}"

# Create trigger JSON
cat > /tmp/trigger.json <<EOF
{
  "trigger_id": "${TRIGGER_ID}",
  "job_name": "${JOB_NAME:-rosa-govcloud-s3-test}",
  "build_id": "${BUILD_ID:-unknown}",
  "prow_job_id": "${PROW_JOB_ID:-unknown}",
  "timestamp": "${TIMESTAMP}",
  "test_type": "s3-integration-test",
  "status": "pending"
}
EOF

log "Trigger metadata:"
cat /tmp/trigger.json

# Test 1: List bucket (verify read access)
log "Test 1: Verifying bucket access..."
if aws s3 ls "s3://${S3_BUCKET}/" > /tmp/bucket-list.txt 2>&1; then
    log "✓ Successfully listed bucket contents"
else
    log "✗ Failed to list bucket"
    cat /tmp/bucket-list.txt
    exit 1
fi

# Test 2: Upload trigger file
log "Test 2: Uploading trigger file to S3..."
S3_PATH="s3://${S3_BUCKET}/prow-triggers/${TRIGGER_ID}.json"
if aws s3 cp /tmp/trigger.json "${S3_PATH}"; then
    log "✓ Successfully uploaded trigger to ${S3_PATH}"
else
    log "✗ Failed to upload trigger file"
    exit 1
fi

# Test 3: Download and verify
log "Test 3: Downloading and verifying trigger file..."
if aws s3 cp "${S3_PATH}" /tmp/downloaded-trigger.json; then
    log "✓ Successfully downloaded trigger file"

    # Verify content matches
    if diff /tmp/trigger.json /tmp/downloaded-trigger.json > /dev/null; then
        log "✓ Downloaded content matches uploaded content"
    else
        log "✗ Content mismatch!"
        exit 1
    fi
else
    log "✗ Failed to download trigger file"
    exit 1
fi

# Test 4: Write trigger ID to shared directory for downstream steps
if [[ -d "${SHARED_DIR}" ]]; then
    echo "${TRIGGER_ID}" > "${SHARED_DIR}/s3-trigger-id.txt"
    echo "${S3_PATH}" > "${SHARED_DIR}/s3-trigger-path.txt"
    log "✓ Saved trigger metadata to SHARED_DIR"
fi

# Test 5: Verify IAM policy scope (should NOT be able to access other buckets)
log "Test 4: Verifying IAM policy scope (negative test)..."
if OUTPUT=$(aws s3 ls s3://cloudtrail-ccb904aa-75ce-3db2-854a-ecab3eb4a5e3/ 2>&1); then
    log "✗ ERROR: Credentials have broader S3 access than expected"
    exit 1
elif echo "$OUTPUT" | grep -q "AccessDenied"; then
    log "✓ Correctly denied access to other buckets (IAM policy working as expected)"
else
    log "✗ ERROR: Unexpected response from IAM scope test"
    echo "$OUTPUT"
    exit 1
fi

log "========================================"
log "All S3 integration tests passed!"
log "Trigger ID: ${TRIGGER_ID}"
log "S3 Path: ${S3_PATH}"
log "========================================"

exit 0
