#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -v

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
NAME=$(cat "${CLUSTER_PROFILE_DIR}/cloud_name")

# Cleanup (delete cluster)
echo "Cleaning up cluster..."
/tmp/kops delete cluster --name="${NAME}" --yes

echo "Cleanup completed (S3 buckets preserved for reuse)."
