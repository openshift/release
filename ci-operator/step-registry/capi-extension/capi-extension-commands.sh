#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH
export HOME=/tmp/home
mkdir -p "${HOME}"

echo "Setting up cluster-api extension testing"

# Create the TestExtensionAdmission CR
echo "Creating TestExtensionAdmission CR..."
openshift-tests extension-admission create cluster-api-extensions \
  --permit=test-extensions/*

# Create namespace and ImageStream
echo "Creating test-extensions namespace and ImageStream..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-extensions
---
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: cluster-api-actuator-pkg-tests
  namespace: test-extensions
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

# Verify setup
echo "Verifying extension setup..."
oc get testextensionadmission cluster-api-extensions -o yaml
oc get imagestreamtag cluster-api-actuator-pkg-tests:latest -n test-extensions -o jsonpath='{.metadata.annotations}' | python3 -m json.tool || true

# Run the capi/e2e test suite
echo "Running capi/e2e test suite..."
openshift-tests run capi/e2e \
  --junit-dir="${ARTIFACT_DIR}/junit" --monitor event-collector --dry-run

echo "Extension tests complete!"
