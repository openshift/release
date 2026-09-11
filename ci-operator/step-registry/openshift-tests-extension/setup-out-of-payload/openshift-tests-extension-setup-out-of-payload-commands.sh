#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH
export HOME=/tmp/home
mkdir -p "${HOME}"

# Required environment variables (validated below):
# - EXTENSION_COMPONENT_NAME: Name of the component (e.g., "cli-manager-operator")
# - EXTENSION_BINARY_PATH: Path to test binary in container (e.g., "/usr/bin/cli-manager-operator-tests-ext.gz")
# - EXTENSION_IMAGE: Container image with the test binary (typically set by CI config)
#
# Optional environment variables:
# - EXTENSION_IMAGESTREAM_NAME: ImageStream name (default: "${EXTENSION_COMPONENT_NAME}-tests")
# - EXTENSION_ADMISSION_NAME: TestExtensionAdmission CR name (default: "${EXTENSION_COMPONENT_NAME}-extensions")
# - EXTENSION_NAMESPACE: Namespace for ImageStream (default: "test-extensions")
# - EXTENSION_PERMIT_PATTERN: Admission permit pattern (default: "test-extensions/*")
# - EXTENSION_IMAGESTREAM_TAG: Tag for ImageStream (default: "latest")
# - EXTENSION_WAIT_TIMEOUT: Timeout in seconds for ImageStream import (default: "300")
# - EXTENSION_SKIP_CRD_INSTALL: Skip CRD installation if set to "true" (default: "false")

# Validate required environment variables
if [[ -z "${EXTENSION_COMPONENT_NAME:-}" ]]; then
  echo "ERROR: EXTENSION_COMPONENT_NAME environment variable is required"
  exit 1
fi

if [[ -z "${EXTENSION_BINARY_PATH:-}" ]]; then
  echo "ERROR: EXTENSION_BINARY_PATH environment variable is required"
  exit 1
fi

if [[ -z "${EXTENSION_IMAGE:-}" ]]; then
  echo "ERROR: EXTENSION_IMAGE environment variable is required"
  exit 1
fi

# Set defaults for optional variables
EXTENSION_IMAGESTREAM_NAME="${EXTENSION_IMAGESTREAM_NAME:-${EXTENSION_COMPONENT_NAME}-tests}"
EXTENSION_ADMISSION_NAME="${EXTENSION_ADMISSION_NAME:-${EXTENSION_COMPONENT_NAME}-extensions}"
EXTENSION_NAMESPACE="${EXTENSION_NAMESPACE:-test-extensions}"
EXTENSION_PERMIT_PATTERN="${EXTENSION_PERMIT_PATTERN:-test-extensions/*}"
EXTENSION_IMAGESTREAM_TAG="${EXTENSION_IMAGESTREAM_TAG:-latest}"
EXTENSION_WAIT_TIMEOUT="${EXTENSION_WAIT_TIMEOUT:-300}"
EXTENSION_SKIP_CRD_INSTALL="${EXTENSION_SKIP_CRD_INSTALL:-false}"

echo "=== Setting up out-of-payload OTE extension: ${EXTENSION_COMPONENT_NAME} ==="
echo "Component: ${EXTENSION_COMPONENT_NAME}"
echo "Binary path: ${EXTENSION_BINARY_PATH}"
echo "ImageStream: ${EXTENSION_IMAGESTREAM_NAME}:${EXTENSION_IMAGESTREAM_TAG}"
echo "Namespace: ${EXTENSION_NAMESPACE}"
echo "Admission CR: ${EXTENSION_ADMISSION_NAME}"

# Install the TestExtensionAdmission CRD (if not skipped)
if [[ "${EXTENSION_SKIP_CRD_INSTALL}" != "true" ]]; then
  echo ""
  echo "Installing TestExtensionAdmission CRD..."
  if ! openshift-tests extension-admission install-crd 2> >(tee /tmp/install-crd.err >&2); then
    if ! grep -qi "already exists" /tmp/install-crd.err; then
      echo "ERROR: Failed to install TestExtensionAdmission CRD"
      exit 1
    fi
    echo "TestExtensionAdmission CRD already exists"
  else
    echo "TestExtensionAdmission CRD installed successfully"
  fi
fi

# Create the TestExtensionAdmission CR
echo ""
echo "Creating TestExtensionAdmission CR..."
openshift-tests extension-admission create "${EXTENSION_ADMISSION_NAME}" \
  --permit="${EXTENSION_PERMIT_PATTERN}"

# Create namespace and ImageStream
echo ""
echo "Creating ${EXTENSION_NAMESPACE} namespace and ImageStream..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${EXTENSION_NAMESPACE}
---
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${EXTENSION_IMAGESTREAM_NAME}
  namespace: ${EXTENSION_NAMESPACE}
spec:
  lookupPolicy:
    local: false
  tags:
  - name: ${EXTENSION_IMAGESTREAM_TAG}
    annotations:
      testextension.redhat.io/component: "${EXTENSION_COMPONENT_NAME}"
      testextension.redhat.io/binary: "${EXTENSION_BINARY_PATH}"
    from:
      kind: DockerImage
      name: ${EXTENSION_IMAGE}
    importPolicy:
      scheduled: false
    referencePolicy:
      type: Source
EOF

# Wait for ImageStream import to complete
echo ""
echo "Waiting for ImageStream import to complete..."
timeout="${EXTENSION_WAIT_TIMEOUT}"
elapsed=0
imagestreamtag="${EXTENSION_IMAGESTREAM_NAME}:${EXTENSION_IMAGESTREAM_TAG}"

while [ $elapsed -lt "$timeout" ]; do
  if oc get imagestreamtag "${imagestreamtag}" -n "${EXTENSION_NAMESPACE}" &>/dev/null; then
    echo "ImageStream import completed successfully"
    break
  fi
  echo "Waiting for ImageStream import... ($elapsed/$timeout seconds)"
  sleep 5
  elapsed=$((elapsed + 5))
done

if [ $elapsed -ge "$timeout" ]; then
  echo "ERROR: Timeout waiting for ImageStream import after ${timeout} seconds"
  echo "ImageStream status:"
  oc get imagestream "${EXTENSION_IMAGESTREAM_NAME}" -n "${EXTENSION_NAMESPACE}" -o yaml || true
  exit 1
fi

# Verify setup
echo ""
echo "=== Verifying extension setup ==="
echo ""
echo "TestExtensionAdmission CR:"
oc get testextensionadmission "${EXTENSION_ADMISSION_NAME}" -o yaml

echo ""
echo "ImageStreamTag annotations:"
oc get imagestreamtag "${imagestreamtag}" -n "${EXTENSION_NAMESPACE}" -o json | jq '.metadata.annotations'

echo ""
echo "=== Out-of-payload OTE extension setup complete ==="
