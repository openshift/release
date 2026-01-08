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
NROP_REPO="https://github.com/openshift-kni/numaresources-operator.git"
NROP_BRANCH="main"
GINKGO_LABEL="(tier0 || tier1 || tier2 || tier3) && !schedrst && !reboot_required && !openshift"
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

echo "================Golang versions================="
ls -ltR "${HOME}"
ls -la "${HOME}"/golang-*

# Set go version
if [[ "${T5CI_VERSION}" == "4.12" ]] || [[ "${T5CI_VERSION}" == "4.13" ]]; then
  source "${HOME}"/golang-1.19
elif [[ "${T5CI_VERSION}" == "4.14" ]] || [[ "${T5CI_VERSION}" == "4.15" ]]; then
  source "${HOME}"/golang-1.20
elif [[ "${T5CI_VERSION}" == "4.16" ]]; then
  source "${HOME}"/golang-1.21.11
elif [[ "${T5CI_VERSION}" == "4.17" ]] || [[ "${T5CI_VERSION}" == "4.18" ]]; then
  source "${HOME}"/golang-1.22.4
else
  # For 4.19+ check if golang-1.23.x is available, install if not
  if ls "${HOME}"/golang-1.23* 1> /dev/null 2>&1; then
    # Find the latest golang-1.23.x version available
    LATEST_GOLANG_123=$(ls "${HOME}"/golang-1.23* | sort -V | tail -1)
    echo "Using pre-installed golang: ${LATEST_GOLANG_123}"
    # shellcheck disable=SC1090
    source "${LATEST_GOLANG_123}"
  else
    # Install golang-1.23 manually in ${HOME} to be consistent
    echo "Installing golang-1.23 for OpenShift ${T5CI_VERSION}"
    GO_VERSION="1.23.6"
    GO_ARCH="linux-amd64"

    # Download and install Go 1.23 in ${HOME}
    cd /tmp
    curl -LO "https://go.dev/dl/go${GO_VERSION}.${GO_ARCH}.tar.gz"
    tar -C "${HOME}" -xzf "go${GO_VERSION}.${GO_ARCH}.tar.gz"
    rm "go${GO_VERSION}.${GO_ARCH}.tar.gz"

    # Create environment setup script for golang-1.23.6
    cat > "${HOME}/golang-1.23.6" << 'EOF'
#!/bin/bash
export GOROOT="${HOME}/go"
export PATH="${GOROOT}/bin:${PATH}"
export GOPATH="${HOME}/go-workspace"
export GOBIN="${GOPATH}/bin"
EOF
    chmod +x "${HOME}/golang-1.23.6"

    # Source the newly created golang-1.23.6 script
    source "${HOME}/golang-1.23.6"
  fi
fi

pushd "${NROP_REPO_DIR}"

echo "Go version: $(go version)"
export GOPATH="${HOME}"/go
export GOBIN="${GOPATH}/bin"

# Deploy and install ginkgo
GOFLAGS='' go install github.com/onsi/ginkgo/v2/ginkgo@latest
export PATH=$PATH:$GOBIN

# Ensure we're in the NROP repository directory before running Go module commands
echo "Current directory: $(pwd)"
echo "Checking for go.mod file..."
if [[ ! -f "go.mod" ]]; then
    echo "Error: go.mod file not found in current directory"
    echo "Directory contents:"
    ls -la
    exit 1
fi

echo "Found go.mod file, proceeding with Go module operations..."
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

echo "Ginkgo command failed with exit code: ${run_tests_status}"

# JUnit to HTML conversion
python3 -m venv "${SHARED_DIR}"/myenv
source "${SHARED_DIR}"/myenv/bin/activate
git clone https://github.com/openshift-kni/telco5gci "${SHARED_DIR}"/telco5gci
pip install -r "${SHARED_DIR}"/telco5gci/requirements.txt

for junit_file in "${ARTIFACT_DIR}"/*.xml; do
    if [ ! -e "${junit_file}" ]; then
        echo "No XML files found in ${ARTIFACT_DIR}."
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
