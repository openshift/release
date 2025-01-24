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

RESULTS_FILE="${TEST_REPOSITORY_DIR}/junit-report.xml"

# Login to the source cluster and add permissions
SOURCE_CLUSTER_DIR=$(find tmp/clusters-data/${TEST_PLATFORM} -type d -name "${SOURCE_CLUSTER_PREFIX}*")
if [ -f "${SOURCE_CLUSTER_DIR}/auth/rosa-admin-password" ]; then
  SOURCE_KUBEADMIN_PASSWORD_FILE="/${SOURCE_CLUSTER_DIR}/auth/rosa-admin-password"
  TEST_USER="rosa-admin"
else
  SOURCE_KUBEADMIN_PASSWORD_FILE="/${SOURCE_CLUSTER_DIR}/auth/kubeadmin-password"
  TEST_USER="kubeadmin"
fi
SOURCE_KUBECONFIG="/${SOURCE_CLUSTER_DIR}/auth/kubeconfig"

echo "Logging into source cluster."
export KUBECONFIG=$SOURCE_KUBECONFIG
SOURCE_KUBEADMIN_PASSWORD=$(cat $SOURCE_KUBEADMIN_PASSWORD_FILE)

API_URL=$(oc whoami --show-server)
oc login ${API_URL} -u ${TEST_USER} -p ${SOURCE_KUBEADMIN_PASSWORD}

# Update admin permission for migration-controller service account
oc adm policy add-cluster-role-to-user cluster-admin -z migration-controller -n openshift-migration

# Login to the target cluster and add permissions
TARGET_CLUSTER_DIR=$(find tmp/clusters-data/${TEST_PLATFORM} -type d -name "${TARGET_CLUSTER_PREFIX}*")
if [ -f "${TARGET_CLUSTER_DIR}/auth/rosa-admin-password" ]; then
  TARGET_KUBEADMIN_PASSWORD_FILE="/${TARGET_CLUSTER_DIR}/auth/rosa-admin-password"
  TEST_USER="rosa-admin"
else
  TARGET_KUBEADMIN_PASSWORD_FILE="/${TARGET_CLUSTER_DIR}/auth/kubeadmin-password"
  TEST_USER="kubeadmin"
fi
TARGET_KUBECONFIG="/${TARGET_CLUSTER_DIR}/auth/kubeconfig"

echo "Logging into target cluster."
export KUBECONFIG=$TARGET_KUBECONFIG
TARGET_KUBEADMIN_PASSWORD=$(cat $TARGET_KUBEADMIN_PASSWORD_FILE)

API_URL=$(oc whoami --show-server)
oc login ${API_URL} -u ${TEST_USER} -p ${TARGET_KUBEADMIN_PASSWORD}

# Update admin permission for migration-controller service account
oc adm policy add-cluster-role-to-user cluster-admin -z migration-controller -n openshift-migration

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
