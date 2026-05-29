#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH
export HOME=/tmp/home
mkdir -p "${HOME}"

echo "Setting up cli-manager-operator extension testing"

openshift-tests extension-admission create cli-manager-extensions \
  --permit=test-extensions/*

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
  name: cli-manager-operator-tests
  namespace: test-extensions
spec:
  lookupPolicy:
    local: false
  tags:
    - name: latest
      annotations:
        testextension.redhat.io/component: "cli-manager-operator"
        testextension.redhat.io/binary: "/usr/bin/cli-manager-operator-tests-ext.gz"
      from:
        kind: DockerImage
        name: ${EXTENSION_IMAGE}
      importPolicy:
        scheduled: false
      referencePolicy:
        type: Source
EOF

echo "Importing image to resolve ImageStreamTag..."
oc import-image cli-manager-operator-tests:latest \
  --from="${EXTENSION_IMAGE}" \
  -n test-extensions \
  --confirm

echo "Annotating ImageStreamTag with extension metadata..."
oc annotate imagestreamtag cli-manager-operator-tests:latest -n test-extensions \
  testextension.redhat.io/component="cli-manager-operator" \
  testextension.redhat.io/binary="/usr/bin/cli-manager-operator-tests-ext.gz" \
  --overwrite

echo "Verifying extension setup..."
oc get testextensionadmission cli-manager-extensions -o yaml
oc get imagestreamtag cli-manager-operator-tests:latest -n test-extensions -o yaml
oc get imagestreamtag cli-manager-operator-tests:latest -n test-extensions -o jsonpath='{.metadata.annotations.testextension\.redhat\.io/component}{"\n"}' | grep -Fx "cli-manager-operator"
oc get imagestreamtag cli-manager-operator-tests:latest -n test-extensions -o jsonpath='{.metadata.annotations.testextension\.redhat\.io/binary}{"\n"}' | grep -Fx "/usr/bin/cli-manager-operator-tests-ext.gz"

echo "Installing krew..."
if ! oc krew version; then
  (
    set -x; cd "$(mktemp -d)" &&
    OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
    ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
    KREW="krew-${OS}_${ARCH}" &&
    curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
    tar zxvf "${KREW}.tar.gz" &&
    ./"${KREW}" install krew
  )
fi
export PATH="${HOME}/.krew/bin:${PATH}"

echo "Running cli-manager-operator OTE test suite..."
openshift-tests run "${TEST_SUITE}" \
  --junit-dir="${ARTIFACT_DIR}/junit"
