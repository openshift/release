#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ ingress metallb gatewayapi conformance test command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

INGRESS_OPERATOR_SRC_DIR="/go/src/github.com/openshift/cluster-ingress-operator"
REMOTE_DEST_DIR="/root/cluster-ingress-operator"

echo "### Copying cluster-ingress-operator source to provisioning host"
ssh "${SSHOPTS[@]}" "root@${IP}" "rm -rf ${REMOTE_DEST_DIR}"
scp "${SSHOPTS[@]}" -r "${INGRESS_OPERATOR_SRC_DIR}" "root@${IP}:/root/"

echo "### Installing Go and setting up environment on provisioning host"
ssh "${SSHOPTS[@]}" "root@${IP}" bash <<'EOF'
  # Detect required Go version from go.mod
  cd /root/cluster-ingress-operator
  REQUIRED_GO_VERSION=$(grep "^go " go.mod | awk '{print $2}')
  echo "Required Go version from go.mod: ${REQUIRED_GO_VERSION}"

  # Check if Go is already installed with the correct version
  INSTALLED_GO_VERSION=""
  if command -v go &> /dev/null; then
    INSTALLED_GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    echo "Installed Go version: ${INSTALLED_GO_VERSION}"
  fi

  # Install Go if not present or version mismatch
  if [ -z "${INSTALLED_GO_VERSION}" ] || [ "${INSTALLED_GO_VERSION}" != "${REQUIRED_GO_VERSION}" ]; then
    echo "Installing Go ${REQUIRED_GO_VERSION}..."
    curl -L "https://go.dev/dl/go${REQUIRED_GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    ln -sf /usr/local/go/bin/go /usr/bin/go
    rm -f /tmp/go.tar.gz
    echo "Go installed: $(go version)"
  else
    echo "Go ${INSTALLED_GO_VERSION} is already installed and matches required version"
  fi

  # Ensure KUBECONFIG is set
  export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

  # Verify cluster access
  echo "Verifying cluster access..."
  oc version || echo "Warning: oc version failed"
  oc get nodes -owide || echo "Warning: failed to get nodes"
EOF

echo "### Running Gateway API conformance tests"

# setting +e so we won't exit in case of test failure and the artifacts are going to be copied
set +e
ssh "${SSHOPTS[@]}" "root@${IP}" bash <<'EOF'
  set -o nounset
  set -o pipefail
  set -x

  cd /root/cluster-ingress-operator
  export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig

  # Run the conformance test
  make gatewayapi-conformance
  exit $?
EOF

TEST_EXIT_CODE=$?

if [ ${TEST_EXIT_CODE} -ne 0 ]; then
  echo "### Tests failed, copying artifacts..."

  # Create artifacts directory if it doesn't exist
  mkdir -p "${ARTIFACT_DIR}"

  # Copy test artifacts if they exist
  ssh "${SSHOPTS[@]}" "root@${IP}" "test -d /root/cluster-ingress-operator/_output && tar czf /tmp/test-artifacts.tar.gz -C /root/cluster-ingress-operator/_output . || echo 'No artifacts found in _output'"
  scp "${SSHOPTS[@]}" "root@${IP}:/tmp/test-artifacts.tar.gz" "${ARTIFACT_DIR}/" 2>/dev/null || echo "No artifacts to copy"

  # Extract artifacts if copied successfully
  if [ -f "${ARTIFACT_DIR}/test-artifacts.tar.gz" ]; then
    tar xzf "${ARTIFACT_DIR}/test-artifacts.tar.gz" -C "${ARTIFACT_DIR}/" || echo "Failed to extract artifacts"
  fi

  exit ${TEST_EXIT_CODE}
fi

set -e

echo "### Gateway API conformance tests completed successfully"
