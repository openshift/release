#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Loading management cluster artifacts from S3 into SHARED_DIR..."

# Configure AWS credentials
if [[ ! -f "/var/run/vault/nutanix-dns/.awscred" ]]; then
    echo "ERROR: AWS credentials not found at /var/run/vault/nutanix-dns/.awscred"
    exit 1
fi

export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/nutanix-dns/.awscred
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
echo "✓ AWS credentials configured"

# Validate ARTIFACTS_SOURCE_URL
if [[ -z "${ARTIFACTS_SOURCE_URL:-}" ]]; then
    echo "ERROR: ARTIFACTS_SOURCE_URL is not set"
    echo "Please set ARTIFACTS_SOURCE_URL to your S3 bucket path"
    echo "Example: s3://my-bucket/mgmt-cluster-artifacts/"
    exit 1
fi

if [[ ! "${ARTIFACTS_SOURCE_URL}" =~ ^s3:// ]]; then
    echo "ERROR: ARTIFACTS_SOURCE_URL must be an S3 URL (s3://...)"
    echo "Got: ${ARTIFACTS_SOURCE_URL}"
    exit 1
fi

echo "Syncing artifacts from: ${ARTIFACTS_SOURCE_URL}"

# Sync all files from S3 to SHARED_DIR
if ! aws s3 sync "${ARTIFACTS_SOURCE_URL%/}/" "${SHARED_DIR}/" --exclude "*" --include "kubeconfig" --include "nutanix_context.sh" --include "proxy-conf.sh" --include "*.pem"; then
    echo "ERROR: Failed to sync artifacts from S3"
    exit 1
fi

echo "✓ Artifacts downloaded from S3"

# List downloaded files
echo ""
echo "Downloaded files:"
ls -lh "${SHARED_DIR}"

# Verify required files
echo ""
echo "=== Verifying required files ==="

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
    echo "ERROR: kubeconfig not found in S3"
    exit 1
fi
echo "✓ kubeconfig found"

if [[ ! -f "${SHARED_DIR}/nutanix_context.sh" ]]; then
    echo "ERROR: nutanix_context.sh not found in S3"
    exit 1
fi
echo "✓ nutanix_context.sh found"

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    echo "✓ proxy-conf.sh found (optional)"
fi

# Verify kubeconfig works
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if ! oc cluster-info >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to cluster with provided kubeconfig"
    exit 1
fi
echo "✓ kubeconfig is valid and cluster is accessible"

# Verify nutanix_context.sh has required variables
source "${SHARED_DIR}/nutanix_context.sh"

missing_vars=()
for var in NUTANIX_ENDPOINT NUTANIX_CLUSTER NUTANIX_SUBNET_UUID; do
    if [[ -z "${!var:-}" ]]; then
        missing_vars+=("$var")
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "WARNING: nutanix_context.sh is missing variables: ${missing_vars[*]}"
else
    echo "✓ nutanix_context.sh contains required variables"
fi

echo ""
echo "=== Artifacts loaded successfully ==="
echo "Management cluster is ready for use"
echo ""
echo "Cluster nodes:"
oc get nodes --no-headers | wc -l | xargs echo "Total nodes:"
