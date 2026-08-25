#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/env"

NAMESPACE="openshift-kueue-operator"

if [[ -z "${BUNDLE_IMAGE:-}" ]]; then
  echo "ERROR: BUNDLE_IMAGE not set. Ensure kueue-operator-image-env-setup ran first."
  exit 1
fi

echo "Installing operator-sdk..."
curl -sLo /tmp/operator-sdk --fail --retry 3 --max-time 120 "https://github.com/operator-framework/operator-sdk/releases/download/v1.39.2/operator-sdk_linux_amd64"
chmod +x /tmp/operator-sdk

echo "Installing kueue operator from CI-built bundle: ${BUNDLE_IMAGE}"

/tmp/operator-sdk run bundle \
  --timeout=10m \
  --security-context-config restricted \
  --skip-tls-verify \
  -n "${NAMESPACE}" \
  "${BUNDLE_IMAGE}"

echo "Bundle installed successfully."
