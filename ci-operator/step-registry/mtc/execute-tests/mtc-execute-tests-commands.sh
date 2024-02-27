#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Move the oc binary
echo "Moving oc binary to /usr/bin/oc"
cp ${TEST_REPOSITORY_DIR}/oc /usr/bin/oc

# Extract all tar files
echo "Extracting cluster data, mtc-apps-deployer, and mtc-python-client."
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data
tar -xf "${TEST_REPOSITORY_DIR}/mtc-apps-deployer.tar.gz" -C "${MTC_APPS_DEPLOYER_DIR}" --strip-components 1
tar -xf "${TEST_REPOSITORY_DIR}/mtc-python-client.tar.gz" -C "${MTC_PYTHON_CLIENT_DIR}" --strip-components 1

# Create a virtual environment
echo "Creating Python virtual environment"
python -m venv ${TEST_REPOSITORY_DIR}/venv
source ${TEST_REPOSITORY_DIR}/venv/bin/activate

# Install required packages
echo "Installing mtc-apps-deployer and mtc-python-client."
python3 -m pip install -r $TEST_REPOSITORY_DIR/requirements.txt --ignore-installed
python3 -m pip install $MTC_APPS_DEPLOYER_DIR
python3 -m pip install $MTC_PYTHON_CLIENT_DIR

TARGET_CLUSTER_DIR=$(find tmp/clusters-data/${TEST_PLATFORM} -type d -name "${TARGET_CLUSTER_PREFIX}*")
TARGET_KUBEADMIN_PASSWORD_FILE="/${TARGET_CLUSTER_DIR}/auth/kubeadmin-password"
TARGET_KUBECONFIG="/${TARGET_CLUSTER_DIR}/auth/kubeconfig"
RESULTS_FILE="${TEST_REPOSITORY_DIR}/junit-report.xml"

# Login to the cluster
echo "Logging into source cluster."
TARGET_KUBEADMIN_PASSWORD=$(cat $TARGET_KUBEADMIN_PASSWORD_FILE)
export KUBECONFIG=$TARGET_KUBECONFIG
oc login -u kubeadmin -p $TARGET_KUBEADMIN_PASSWORD

# Define archive-results function
function archive-results() {
    if [[ -f "${RESULTS_FILE}" ]] && [[ ! -f "${ARTIFACT_DIR}/junit_mtc_interop_results.xml" ]]; then
        echo "Copying ${RESULTS_FILE} to ${ARTIFACT_DIR}/junit_mtc_interop_results.xml..."
        cp "${RESULTS_FILE}" "${ARTIFACT_DIR}/junit_mtc_interop_results.xml"
    fi
}

# Execute scenario
echo "Executing tests."
trap archive-results SIGINT SIGTERM ERR EXIT
pytest ${TEST_REPOSITORY_DIR}/mtc_tests/tests/test_interop.py -srA --junit-xml=${RESULTS_FILE}
