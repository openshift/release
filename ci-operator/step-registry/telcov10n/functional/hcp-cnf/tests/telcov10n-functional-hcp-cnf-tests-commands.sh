#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ telco5g cnf-tests commands ************"

# Environment Variables required for running the test
export CLUSTER_NAME=cnfqe1
export ROLE_WORKER_CNF=worker
export HYPERSHIFT_HOSTED_CLUSTER_KUBECONFIG="${SHARED_DIR}"/kubeconfig
export HYPERSHIFT_HOSTED_CONTROL_PLANE_NAMESPACE=clusters-cnfqe1
export CLUSTER_TYPE=hypershift
export HYPERSHIFT_MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}"/mgmt-kubeconfig
export KUBECONFIG="${SHARED_DIR}"/kubeconfig
export HYPERSHIFT_MANAGEMENT_CLUSTER_NAMESPACE=clusters-cnfqe1

#### Local variables
TELCO_CI_REPO="https://github.com/openshift-kni/telco-ci.git"
NTO_REPO="https://github.com/openshift/cluster-node-tuning-operator.git"

NTO_BRANCH="master"
GINKGO_LABEL="tier-0"
GINKGO_SUITES="test/e2e/performanceprofile/functests"

[[ -f "${SHARED_DIR}"/main.env ]] && source "${SHARED_DIR}"/main.env || echo "No main.env file found"

### This need cleanups/
function clonerepo() {
        git clone -b "${NTO_BRANCH}" "${NTO_REPO}" "${NTO_REPO_DIR}"
}

# Fix user ID's in a container
~/fix_uid.sh

echo "******************* Telco CNF Compute QE Setup Command ******************"
date +%s > "${SHARED_DIR}"/start_time

##clone the github/openshift-kni/telco5g-ci
mkdir -p "${SHARED_DIR}"/repos
git clone "${TELCO_CI_REPO}" "${SHARED_DIR}"/repos/telco-ci

#install ansible modules
ansible-galaxy collection install -r "${SHARED_DIR}"/repos/telco-ci/ansible-requirements.yaml

### lets display the contents of ${SHARED_DIR}
ls -ltR "${SHARED_DIR}"
 
# Applying Performance Profile into the cluster
# TODO: Check if the kubeconfig file exists
echo "**************Applying Performance Profile **************"
export ANSIBLE_CONFIG="${SHARED_DIR}"/repos/telco-ci/ansible.cfg
ansible-playbook -vvvv "${SHARED_DIR}"/repos/telco-ci/playbooks/performance_profile.yml -e kubeconfig="${SHARED_DIR}"/mgmt-kubeconfig -c local

#### If we made this far we are good with running tests
echo "********************* Running Tests ****************************"

if (( $(echo "${T5CI_VERSION} < 4.18" | bc -l) )); then
    NTO_BRANCH="release-${T5CI_VERSION}"
fi

## create NTO REPO DIR only if we have come this far
NTO_REPO_DIR=${NTO_REPO_DIR:-"$(mktemp -d -t nto-XXXXX)/cluster-node-tuning-operator"}

mkdir -p "${NTO_REPO_DIR}"
echo "Running on branch ${NTO_BRANCH}"
echo "!!!!!!!!!!!!!!!!!!! CLONING THE NTO REPO !!!!!!!!!!!!!!!!!!!"
clonerepo
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

## Install ginkgo
export GOPATH="${HOME}"/go
export GOBIN="${GOPATH}"/bin

# Deploy ginkgo
go install github.com/onsi/ginkgo/v2/ginkgo@latest
go install github.com/onsi/gomega@latest

echo "************ telco5g cnf-tests commands ************"
export PATH=$PATH:$GOBIN

echo "Running ${GINKGO_LABEL} tests"
GOFLAGS=-mod=vendor ginkgo --no-color --v -r ${GINKGO_SUITES}  \
--timeout=1h --keep-separate-reports --keep-going --flake-attempts=2 \
--label-filter="${GINKGO_LABEL}" --junit-report=_report_${GINKGO_LABEL}.xml --output-dir="${ARTIFACT_DIR}"

popd

echo "************ FINISHED THE TEST SCRIPT ************"
