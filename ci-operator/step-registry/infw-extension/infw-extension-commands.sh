#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH
export HOME=/tmp/home
mkdir -p "${HOME}"

echo "Setting up ingress-node-firewall extension testing"
echo "Extension image: ${EXTENSION_IMAGE}"

# Create the TestExtensionAdmission CR
echo "Creating TestExtensionAdmission CR..."
openshift-tests extension-admission create infw-extensions \
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
  name: ingress-node-firewall-tests
  namespace: test-extensions
spec:
  lookupPolicy:
    local: false
  tags:
    - name: latest
      annotations:
        testextension.redhat.io/component: "ingress-node-firewall"
        testextension.redhat.io/binary: "/usr/bin/ingress-node-firewall-tests.gz"
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
oc get testextensionadmission infw-extensions -o yaml
oc get imagestreamtag ingress-node-firewall-tests:latest -n test-extensions -o jsonpath='{.metadata.annotations}' | python3 -m json.tool || true

echo "Ingress Node Firewall extension setup complete!"

# Run the extension tests
SUITE="${INFW_TEST_SUITE:-openshift/ingress-node-firewall/aws}"
echo "Running ingress-node-firewall extension tests (suite: ${SUITE})..."
openshift-tests run "${SUITE}" \
    --junit-dir="${ARTIFACT_DIR}/junit"
