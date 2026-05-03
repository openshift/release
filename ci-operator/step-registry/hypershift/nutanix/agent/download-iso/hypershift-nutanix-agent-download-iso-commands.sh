#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Download Agent ISO for HyperShift Hosted Cluster ************"

# Get hosted cluster information
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}')
HOSTED_CLUSTER_NAME=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.name}')
HOSTED_CONTROL_PLANE_NAMESPACE="${HOSTED_CLUSTER_NS}-${HOSTED_CLUSTER_NAME}"

echo "$(date -u --rfc-3339=seconds) - Hosted cluster: ${HOSTED_CLUSTER_NAME}"
echo "$(date -u --rfc-3339=seconds) - Control plane namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}"

# Wait for InfraEnv ISO to be created
echo "$(date -u --rfc-3339=seconds) - Waiting for InfraEnv ISO to be created..."
oc wait --timeout=15m --for=condition=ImageCreated \
    -n ${HOSTED_CONTROL_PLANE_NAMESPACE} \
    InfraEnv/${HOSTED_CLUSTER_NAME}

# Get ISO download URL
ISO_DOWNLOAD_URL=$(oc get InfraEnv/${HOSTED_CLUSTER_NAME} \
    -n ${HOSTED_CONTROL_PLANE_NAMESPACE} \
    -ojsonpath='{.status.isoDownloadURL}')

if [ -z "${ISO_DOWNLOAD_URL}" ]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: ISO download URL is empty"
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - ISO Download URL: ${ISO_DOWNLOAD_URL}"

# Download ISO to local filesystem (required by Terraform)
ISO_LOCAL_PATH="${SHARED_DIR}/agent-worker.iso"
echo "$(date -u --rfc-3339=seconds) - Downloading ISO to ${ISO_LOCAL_PATH}..."

curl -L --fail -o "${ISO_LOCAL_PATH}" --insecure "${ISO_DOWNLOAD_URL}"

# Verify download
if [ ! -f "${ISO_LOCAL_PATH}" ]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: ISO file not found after download"
    exit 1
fi

FILE_SIZE=$(du -h "${ISO_LOCAL_PATH}" | cut -f1)
echo "$(date -u --rfc-3339=seconds) - Downloaded ISO: ${FILE_SIZE}"

# Save ISO path for Terraform step
echo "${ISO_LOCAL_PATH}" > "${SHARED_DIR}/iso-local-path.txt"

echo "$(date -u --rfc-3339=seconds) - ISO download completed successfully"
