#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ telco5g cnf-tests commands ************"

# Environment Variables required for running the test
export KUBECONFIG="${SHARED_DIR}"/kubeconfig
export ROLE_WORKER_CNF=worker
export CLUSTER_NAME=cnfqe1
export CLUSTER_TYPE=hypershift
export HYPERSHIFT_MANAGEMENT_CLUSTER_NAMESPACE=clusters-cnfqe1
export HYPERSHIFT_MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}"/mgmt-kubeconfig
export HYPERSHIFT_HOSTED_CLUSTER_KUBECONFIG="${SHARED_DIR}"/kubeconfig
export HYPERSHIFT_HOSTED_CONTROL_PLANE_NAMESPACE=clusters-cnfqe1

# local variables
TELCO_CI_REPO="https://github.com/openshift-kni/telco-ci.git"
NTO_REPO="https://github.com/openshift/cluster-node-tuning-operator.git"
NTO_BRANCH="master"
GINKGO_LABEL="(!openshift && tier-0)"
GINKGO_SUITES="test/e2e/performanceprofile/functests/1_performance"

[[ -f "${SHARED_DIR}"/main.env ]] && source "${SHARED_DIR}"/main.env || echo "No main.env file found"

# Fix user ID's in a container
~/fix_uid.sh

echo "************ Telco CNF Compute QE Setup Command ************"
date +%s > "${SHARED_DIR}"/start_time

mkdir -p "${SHARED_DIR}"/repos
git clone "${TELCO_CI_REPO}" "${SHARED_DIR}"/repos/telco-ci

# install ansible modules
ansible-galaxy collection install -r "${SHARED_DIR}"/repos/telco-ci/ansible-requirements.yaml

# applying Performance Profile into the cluster
echo "************ Applying Performance Profile ************"
export ANSIBLE_CONFIG="${SHARED_DIR}"/repos/telco-ci/ansible.cfg
ansible-playbook -vv "${SHARED_DIR}"/repos/telco-ci/playbooks/performance_profile.yml -e kubeconfig="${SHARED_DIR}"/mgmt-kubeconfig -c local

# checking to see if a release branch is needed or master
if awk "BEGIN {exit !($T5CI_VERSION < 4.19)}"; then
    NTO_BRANCH="release-${T5CI_VERSION}"
fi

# creating the NTO dir and cloning the necessary branch
NTO_REPO_DIR=${NTO_REPO_DIR:-"$(mktemp -d -t nto-XXXXX)/cluster-node-tuning-operator"}
mkdir -p "${NTO_REPO_DIR}"
echo "Running on branch ${NTO_BRANCH}"
git clone -b "${NTO_BRANCH}" "${NTO_REPO}" "${NTO_REPO_DIR}"
pushd "${NTO_REPO_DIR}"

# Set go version
if [[ "$T5CI_VERSION" == "4.12" ]] || [[ "$T5CI_VERSION" == "4.13" ]]; then
    source "$HOME"/golang-1.19
elif [[ "$T5CI_VERSION" == "4.14" ]] || [[ "$T5CI_VERSION" == "4.15" ]]; then
    source "$HOME"/golang-1.20
elif [[ "$T5CI_VERSION" == "4.16" ]]; then
    source "$HOME"/golang-1.21.11
else
    source "$HOME"/golang-1.22.4
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
make vet

echo "************ Running ${GINKGO_LABEL} tests ************"
GOFLAGS=-mod=vendor ginkgo --no-color -v --label-filter="${GINKGO_LABEL}" \
--timeout=1h --keep-separate-reports --keep-going --flake-attempts=2 \
--junit-report=tier-0-junit.xml --output-dir="${ARTIFACT_DIR}" --require-suite "${GINKGO_SUITES}"

popd
