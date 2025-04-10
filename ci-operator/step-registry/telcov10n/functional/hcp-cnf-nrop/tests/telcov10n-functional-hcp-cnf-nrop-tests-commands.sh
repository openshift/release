#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ telco5g cnf-tests commands ************"

# Cluster necessary env variables
export KUBECONFIG="${SHARED_DIR}"/kubeconfig
export HYPERSHIFT_MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}"/mgmt-kubeconfig

# NROP serial suite necessary env variables
# docs for these env variables can be found here: https://github.com/openshift-kni/numaresources-operator/tree/main/test/e2e/serial
export E2E_NROP_DEVICE_TYPE_1=example.com/deviceA
export E2E_NROP_DEVICE_TYPE_2=example.com/deviceB
export E2E_NROP_DEVICE_TYPE_3=example.com/deviceC

# local variables
NROP_REPO="https://github.com/openshift/numaresources-operator.git"
NROP_BRANCH="main"
GINKGO_LABEL="tier0 && !reboot_required && !openshift"
GINKGO_SUITES="test/e2e/serial/"

[[ -f "${SHARED_DIR}"/main.env ]] && source "${SHARED_DIR}"/main.env || echo "No main.env file found"

# Fix user ID's in a container
~/fix_uid.sh

# checking to see if a release branch is needed or main
if awk "BEGIN {exit !($T5CI_VERSION < 4.19)}"; then
    NROP_BRANCH="release-${T5CI_VERSION}"
fi

# creating the NROP dir and cloning the necessary branch
NROP_REPO_DIR=${NROP_REPO_DIR:-"$(mktemp -d -t nto-XXXXX)/numaresources-operator"}
mkdir -p "${NROP_REPO_DIR}"
echo "Running on branch ${NROP_BRANCH}"
git clone -b "${NROP_BRANCH}" "${NROP_REPO}" "${NROP_REPO_DIR}"
pushd "${NROP_REPO_DIR}"

# Set go version
if [[ "${T5CI_VERSION}" == "4.12" ]] || [[ "${T5CI_VERSION}" == "4.13" ]]; then
    source "${HOME}"/golang-1.19
elif [[ "${T5CI_VERSION}" == "4.14" ]] || [[ "${T5CI_VERSION}" == "4.15" ]]; then
    source "${HOME}"/golang-1.20
elif [[ "${T5CI_VERSION}" == "4.16" ]]; then
    source "${HOME}"/golang-1.21.11
else
    source "${HOME}"/golang-1.22.4
fi

echo "Go version: $(go version)"
export GOPATH="${HOME}"/go
export GOBIN="${GOPATH}"/bin

# Deploy and install ginkgo
GOFLAGS='' go install github.com/onsi/ginkgo/v2/ginkgo@latest
export PATH=$PATH:$GOBIN
go get github.com/onsi/gomega@latest
go mod tidy
go mod vendor
# make commands required to run tests
make vet
make update-buildinfo
run_tests_status=0
run_tests() {
    echo "************ Running NROP serial test suite with ${GINKGO_LABEL} labels ************"
    GOFLAGS=-mod=vendor ginkgo --no-color -v --label-filter="${GINKGO_LABEL}" \
    --timeout=24h --keep-separate-reports --keep-going --flake-attempts=2 \
    --junit-report=tier-0-junit.xml --output-dir="${ARTIFACT_DIR}" -r ${GINKGO_SUITES}
}

echo "************ Starting NROP tests ************"

run_tests || run_tests_status=$?
echo "Test status: ${run_tests_status}"
popd
