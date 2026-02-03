#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ telco verfication functional tests commands ************"

# Environment Variables required for running the test
export KUBECONFIG="${SHARED_DIR}"/kubeconfig
export ROLE_WORKER_CNF=worker-cnf

# local variables
TELCO_CI_REPO="https://github.com/openshift-kni/telco-ci.git"
NTO_REPO="https://github.com/openshift/cluster-node-tuning-operator.git"
NTO_BRANCH=$(git ls-remote --heads ${NTO_REPO} main | grep -q 'refs/heads/main'  && echo 'main' || echo 'master')
GINKGO_LABEL="uncore-cache"
GINKGO_SUITES="test/e2e/performanceprofile/functests/13_llc"

[[ -f "${SHARED_DIR}"/main.env ]] && source "${SHARED_DIR}"/main.env || echo "No main.env file found"

# Fix user ID's in a container
~/fix_uid.sh

echo "************ Telco CNF Compute QE Setup Command ************"
date +%s > "${SHARED_DIR}"/start_time

mkdir -p "${SHARED_DIR}"/repos
git clone "${TELCO_CI_REPO}" "${SHARED_DIR}"/repos/telco-ci

# install ansible modules
ansible-galaxy collection install -r "${SHARED_DIR}"/repos/telco-ci/ansible-requirements.yaml

#Find Baremetal worker nodes
function is_bm_node () {
    node=$1

    CPU_THRESHOLD=79
    MEM_THRESHOLD=80 # in Gi (80 GB)

    echo "Check if node ${node} is baremetal or virtual"

    # Get CPU and memory capacity of the nodes
    cpu=$(oc get ${node} -o jsonpath='{.status.capacity.cpu}')
    memory=$(oc get ${node} -o jsonpath='{.status.capacity.memory}')

    # Handle both Ki and Mi memory units
    if [[ ${memory} == *Ki ]]; then
        memory=${memory%Ki}
        memory=$((memory / 1024 / 1024 ))  # Convert Ki to Gi
    elif [[ ${memory} == *Mi ]]; then
        memory=${memory%Mi}
        memory=$((memory / 1024 ))  # Convert Mi to Gi
    else
        echo "Warning: Unknown memory unit for ${memory}"
        memory=0
    fi

    if [[ ${cpu} -gt ${CPU_THRESHOLD} && ${memory} -gt ${MEM_THRESHOLD} ]]; then
        echo "Node ${node} is a baremetal node"
        return 0
    else
       echo "Node ${node} is a virtual node"
       return 1
    fi
}

# Label Baremetal worker nodes as worker-cnf
worker_nodes=$(oc get nodes --selector='node-role.kubernetes.io/worker' \
    --selector='!node-role.kubernetes.io/master' -o name)
if [ -z "${worker_nodes}" ]; then
    echo "No worker nodes found"
    exit 1
fi
test_nodes=""
for node in ${worker_nodes}; do
    if is_bm_node ${node}; then
        test_nodes="${test_nodes} ${node}"
    fi
done
if [ -z "${test_nodes}" ]; then
    echo "No baremetal nodes found"
    exit 1
fi
echo "Baremetal nodes found: ${test_nodes}"


# Label baremetal nodes with worker-cnf role
echo "************ Labeling baremetal nodes with worker-cnf role ************"
for node in ${test_nodes}; do
    echo "Labeling ${node} with node-role.kubernetes.io/worker-cnf"
    oc label ${node} node-role.kubernetes.io/worker-cnf="" --overwrite
done


## Print the nodes in the cluster
oc get nodes


# Create worker-cnf mcp and applying Performance Profile into the cluster
echo "************ Applying Performance Profile ************"
export ANSIBLE_CONFIG="${SHARED_DIR}"/repos/telco-ci/ansible.cfg
ls -l "${SHARED_DIR}"
ansible-playbook -vv "${SHARED_DIR}"/repos/telco-ci/playbooks/llc.yaml -e kubeconfig="${SHARED_DIR}"/kubeconfig -c local

# checking to see if a release branch is needed or main
if awk "BEGIN {exit !($T5CI_VERSION < 4.20)}"; then
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
export IMAGE_REGISTRY=quay.io/openshift-kni/
export CNF_TESTS_IMAGE=cnf-tests:latest

## Print the nodes in the cluster
oc get nodes

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

run_tests || run_tests_status=$?
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
