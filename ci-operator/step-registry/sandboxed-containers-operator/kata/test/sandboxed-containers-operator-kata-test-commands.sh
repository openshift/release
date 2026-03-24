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

echo "Installing required packages"
if ! command -v git &>/dev/null; then
	dnf install -y git-core
fi

KATA_REPO="${KATA_REPO:-https://github.com/openshift/kata-containers.git}"
KATA_BRANCH="${KATA_BRANCH:-osc-release}"
KATA_DIR="/tmp/kata-containers"

echo "Cloning ${KATA_REPO} (branch: ${KATA_BRANCH})"
git clone --depth 1 --branch "${KATA_BRANCH}" "${KATA_REPO}" "${KATA_DIR}"

echo "Installing test dependencies"
# bats
if ! command -v bats &>/dev/null; then
	git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
	pushd /tmp/bats-core
	./install.sh /usr/local
	popd
fi

# yq
if ! command -v yq &>/dev/null; then
	curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
		-o /usr/local/bin/yq
	chmod +x /usr/local/bin/yq
fi

echo "Running upstream kata-containers tests"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export TESTS_FILTER="${KATA_TESTS_FILTER:-}"
export K8S_TEST_FAIL_FAST="${KATA_TESTS_FAIL_FAST:-no}"

"${KATA_DIR}/redhat/tests/run-tests.sh"
