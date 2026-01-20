#!/bin/bash

set -o nounset
set -o pipefail

echo "========================================="
echo "Cleaning up mock KMS plugin"
echo "========================================="

# Read namespace from SHARED_DIR if it exists
if [ -f "${SHARED_DIR}/kms-plugin-namespace" ]; then
  KMS_NAMESPACE=$(cat "${SHARED_DIR}/kms-plugin-namespace")
else
  KMS_NAMESPACE="openshift-kms-plugin"
fi

echo "Deleting namespace: ${KMS_NAMESPACE}"
oc delete namespace "${KMS_NAMESPACE}" --ignore-not-found=true --wait=false

# Clean up SHARED_DIR files
echo "Cleaning up SHARED_DIR files..."
rm -f "${SHARED_DIR}/kms-plugin-socket-path"
rm -f "${SHARED_DIR}/kms-plugin-namespace"

echo ""
echo "✓ KMS plugin cleanup completed"
