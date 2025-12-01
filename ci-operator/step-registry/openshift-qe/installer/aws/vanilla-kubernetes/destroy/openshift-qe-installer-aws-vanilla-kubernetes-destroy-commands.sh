#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -v

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
NAME=$(cat "${CLUSTER_PROFILE_DIR}/cloud_name")

# Download latest kops binary
echo "Downloading latest kops binary..."
pushd /tmp
curl -Lo kops "https://github.com/kubernetes/kops/releases/download/$(curl -s https://api.github.com/repos/kubernetes/kops/releases/latest | jq -r '.tag_name')/kops-linux-amd64"
chmod +x kops

# Cleanup (delete cluster)
echo "Cleaning up cluster..."
./kops delete cluster --name="${NAME}" --yes

echo "Cleanup completed (S3 buckets preserved for reuse)."
