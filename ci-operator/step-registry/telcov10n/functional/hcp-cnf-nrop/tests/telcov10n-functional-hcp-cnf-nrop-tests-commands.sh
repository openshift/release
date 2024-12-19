#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ telco5g nrop-tests commands ************"

# Cluster necessary env variables
export KUBECONFIG="${SHARED_DIR}"/kubeconfig
export HYPERSHIFT_MANAGEMENT_CLUSTER_KUBECONFIG="${SHARED_DIR}"/mgmt-kubeconfig

# NROP serial suite necessary env variables
# docs for these env variables can be found here: https://github.com/openshift-kni/numaresources-operator/tree/main/test/e2e/serial
export E2E_NROP_DEVICE_TYPE_1=example.com/deviceA
export E2E_NROP_DEVICE_TYPE_2=example.com/deviceB
export E2E_NROP_DEVICE_TYPE_3=example.com/deviceC

# local variables
TELCO_CI_REPO="https://github.com/openshift-kni/telco-ci.git"
NROP_REPO="https://github.com/openshift/numaresources-operator.git"
NROP_BRANCH="main"
GINKGO_LABEL="tier0 && !reboot_required && !openshift"
GINKGO_SUITES="test/e2e/serial/"

[[ -f "${SHARED_DIR}"/main.env ]] && source "${SHARED_DIR}"/main.env || echo "No main.env file found"

# Fix user ID's in a container
~/fix_uid.sh

echo "************ Telco CNF Compute QE Setup Command ************"
date +%s > "${SHARED_DIR}"/start_time

mkdir -p "${SHARED_DIR}"/repos
git clone "${TELCO_CI_REPO}" "${SHARED_DIR}"/repos/telco-ci

# install ansible modules
ansible-galaxy collection install -r "${SHARED_DIR}"/repos/telco-ci/ansible-requirements.yaml

# Applying necessary certs before NROP operator installation
echo "************ Applying Certs ************"
ansible-playbook -vv playbooks/apply_registry_certs.yml -e kubeconfig="${HYPERSHIFT_MANAGEMENT_CLUSTER_KUBECONFIG}" -c local

# Installing NROP Operator before applying the Performance Profile without scheduler
echo "************ Installing NROP operator ************"
ansible-playbook -vv playbooks/install_nrop.yml -e kubeconfig="${SHARED_DIR}"/kubeconfig -c local

# Installing the secondary scheduler CR
echo "************ Applying the NROP secondary-scheduler ************"
ansible-playbook -vv playbooks/apply_nrop_scheduler.yml -e kubeconfig="${SHARED_DIR}"/kubeconfig -c local

# applying Performance Profile into the cluster
echo "************ Applying Performance Profile ************"
export ANSIBLE_CONFIG="${SHARED_DIR}"/repos/telco-ci/ansible.cfg
ansible-playbook -vv "${SHARED_DIR}"/repos/telco-ci/playbooks/performance_profile.yml -e kubeconfig="${SHARED_DIR}"/mgmt-kubeconfig -c local

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
make vet

run_tests() {
    echo "************ Running NROP serial test suite with ${GINKGO_LABEL} labels ************"
    GOFLAGS=-mod=vendor ginkgo --no-color -v --label-filter="${GINKGO_LABEL}" \
    --timeout=24h --keep-separate-reports --keep-going --flake-attempts=2 \
    --junit-report=tier-0-junit.xml --output-dir="${ARTIFACT_DIR}" -r ${GINKGO_SUITES}
}

run_tests
popd


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
