#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH
export HOME=/tmp/home
mkdir -p "${HOME}"

echo "Setting up cluster-api-actuator-pkg extension testing"
echo "Extension image: ${EXTENSION_IMAGE}"

# Detect current platform
PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || echo "unknown")
echo "Detected platform: ${PLATFORM}"

# 1. Create TestExtensionAdmission CR
echo "Creating TestExtensionAdmission CR..."
openshift-tests extension-admission create cluster-api-extensions \
  --permit="${EXTENSION_NAMESPACE}/*"

# 2. Create namespace and ImageStream
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
  name: cluster-api-actuator-pkg-tests
  namespace: ${EXTENSION_NAMESPACE}
spec:
  lookupPolicy:
    local: false
  tags:
    - name: latest
      annotations:
        testextension.redhat.io/component: "cluster-api-actuator-pkg"
        testextension.redhat.io/binary: "/cluster-api-actuator-pkg-tests-ext.gz"
      from:
        kind: DockerImage
        name: ${EXTENSION_IMAGE}
      importPolicy:
        scheduled: false
      referencePolicy:
        type: Source
EOF

# 3. Wait for ImageStream import
echo "Waiting for ImageStream import..."
oc wait --for=condition=ImageImported \
  imagestreamtag/cluster-api-actuator-pkg-tests:latest \
  -n ${EXTENSION_NAMESPACE} \
  --timeout=300s || {
    echo "ImageStream import failed!"
    oc describe imagestreamtag/cluster-api-actuator-pkg-tests:latest -n ${EXTENSION_NAMESPACE}
    exit 1
  }

# 4. Verify setup
echo "Verifying extension setup..."
oc get testextensionadmission cluster-api-extensions -o yaml
echo "---"
oc get imagestreamtag cluster-api-actuator-pkg-tests:latest -n ${EXTENSION_NAMESPACE} -o jsonpath='{.metadata.annotations}' | python3 -m json.tool || true

# 5. List tests that will run (dry-run)
echo "Listing tests in suite: ${TEST_SUITE}"
openshift-tests run "${TEST_SUITE}" \
  --dry-run=true \
  | head -50

# 6. Run tests
echo "Running test suite: ${TEST_SUITE} on platform: ${PLATFORM}"
openshift-tests run "${TEST_SUITE}" \
  --junit-dir="${ARTIFACT_DIR}/junit"

echo "Extension tests complete!"
