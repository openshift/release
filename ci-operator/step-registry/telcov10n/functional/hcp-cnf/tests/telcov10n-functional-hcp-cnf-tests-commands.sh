#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ telco5g cnf-tests commands ************"

# Environment Variables required for running the test
export KUBECONFIG="${SHARED_DIR}"/mgmt-kubeconfig
NODEPOOL_NAME=$(oc get np -n clusters -o json | jq -r '.items[0].metadata.name')
export KUBECONFIG="${SHARED_DIR}"/kubeconfig
export ROLE_WORKER_CNF=worker
export CLUSTER_NAME="${NODEPOOL_NAME}"
export CLUSTER_TYPE=hypershift
export HYPERSHIFT_MANAGEMENT_CLUSTER_NAMESPACE=clusters-"${NODEPOOL_NAME}"
export HYPERSHIFT_MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}"/mgmt-kubeconfig
export HYPERSHIFT_HOSTED_CLUSTER_KUBECONFIG="${SHARED_DIR}"/kubeconfig
export HYPERSHIFT_HOSTED_CONTROL_PLANE_NAMESPACE=clusters-"${NODEPOOL_NAME}"

# local variables
TELCO_CI_REPO="https://github.com/openshift-kni/telco-ci.git"
NTO_REPO="https://github.com/openshift/cluster-node-tuning-operator.git"
NTO_BRANCH=$(git ls-remote --heads ${NTO_REPO} main | grep -q 'refs/heads/main'  && echo 'main' || echo 'master')
GINKGO_LABEL="tier-0 && !openshift"
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

# checking to see if a release branch is needed or main
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
make vet

run_tests_status=0

run_tests() {
    echo "************ Running ${GINKGO_LABEL} tests ************"
    GOFLAGS=-mod=vendor ginkgo --no-color -v --label-filter="${GINKGO_LABEL}" \
    --timeout=24h --keep-separate-reports --keep-going --flake-attempts=2 \
    --junit-report=junit.xml --output-dir="${ARTIFACT_DIR}" -r ${GINKGO_SUITES}
}

if [[ "${T5CI_VERSION}" == "4.17" ]]; then
    run_tests || run_tests_status=$?
else
    GINKGO_LABEL="(tier-0 || tier-1 || tier-2 || tier-3) && !openshift"
    GINKGO_SUITES="test/e2e/performanceprofile/functests/1_performance test/e2e/performanceprofile/functests/2_performance_update test/e2e/performanceprofile/functests/3_performance_status  test/e2e/performanceprofile/functests/7_performance_kubelet_node test/e2e/performanceprofile/functests/8_performance_workloadhints"
    run_tests || run_tests_status=$?
fi
popd

echo "Ginkgo command failed with exit code: ${run_tests_status}"

python3 -m venv "${SHARED_DIR}"/myenv
source "${SHARED_DIR}"/myenv/bin/activate
git clone https://github.com/openshift-kni/telco5gci "${SHARED_DIR}"/telco5gci
pip install -r "${SHARED_DIR}"/telco5gci/requirements.txt

for junit_file in "${ARTIFACT_DIR}"/*.xml; do
    if [ ! -e "${junit_file}" ]; then
        echo "No XML files found in ${ARTIFACTS_DIR}."
        exit 0
    fi
    output_file="${junit_file%.xml}.html"
    # Run j2html.py on the XML file
    echo "Processing ${junit_file} -> ${output_file}"
    python "${SHARED_DIR}"/telco5gci/j2html.py "${junit_file}" -o "${output_file}"
    if [[ $? -ne 0 ]]; then
         echo "Error: Failed to process ${junit_file}."
         exit 1;
    fi

    # create json reports
    json_output_file="${junit_file%.xml}.json"
    python "${SHARED_DIR}"/telco5gci/junit2json.py "${junit_file}" -o "${json_output_file}"
done

# Run junitparser merge

xml_files=("$ARTIFACT_DIR"/*.xml)
output_file="${ARTIFACT_DIR}"/junit.xml

# Merge XML files using junitparser
echo "Merging XML files into ${output_file}"
junitparser merge "${xml_files[@]}" "${output_file}"

rm -rf "${SHARED_DIR}"/myenv "${SHARED_DIR}"/telco5gci
set +x
set -e
