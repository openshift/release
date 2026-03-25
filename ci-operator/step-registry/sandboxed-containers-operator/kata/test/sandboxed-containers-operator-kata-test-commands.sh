#!/bin/bash
#
# Run kata-containers upstream integration tests on an OpenShift cluster
# with OpenShift Sandboxed Containers installed.
#
# This step is only executed when WORKLOAD_TO_TEST=kata.

set -o nounset
set -o errexit
set -o pipefail

WORKLOAD_TO_TEST="${WORKLOAD_TO_TEST:-}"

if [[ "${WORKLOAD_TO_TEST}" != "kata" ]]; then
	echo "WORKLOAD_TO_TEST=${WORKLOAD_TO_TEST}. Skipping kata upstream tests."
	exit 0
fi

KATA_REPO="${KATA_REPO:-https://github.com/openshift/kata-containers.git}"
KATA_BRANCH="${KATA_BRANCH:-osc-release}"
KATA_DIR="/tmp/kata-containers"

# Convert git URL to tarball URL (works for github.com repos)
TARBALL_URL="${KATA_REPO%.git}/archive/refs/heads/${KATA_BRANCH}.tar.gz"

echo "Downloading ${TARBALL_URL}"
curl -sL "${TARBALL_URL}" | tar xz -C /tmp
mv "/tmp/kata-containers-${KATA_BRANCH}" "${KATA_DIR}"

echo "Installing test dependencies"
TOOLS_DIR="/tmp/tools"
mkdir -p "${TOOLS_DIR}/bin"
export PATH="${TOOLS_DIR}/bin:${PATH}"

# bats
if ! command -v bats &>/dev/null; then
	curl -sL "https://github.com/bats-core/bats-core/archive/refs/heads/master.tar.gz" | tar xz -C /tmp
	pushd /tmp/bats-core-master
	./install.sh "${TOOLS_DIR}"
	popd
fi

# yq
if ! command -v yq &>/dev/null; then
	curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
		-o "${TOOLS_DIR}/bin/yq"
	chmod +x "${TOOLS_DIR}/bin/yq"
fi

echo "Running upstream kata-containers tests"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export TESTS_FILTER="${KATA_TESTS_FILTER:-}"
export K8S_TEST_FAIL_FAST="${KATA_TESTS_FAIL_FAST:-no}"

"${KATA_DIR}/redhat/tests/run-tests.sh"
