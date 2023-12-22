#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set variables needed for test execution
export PROVIDER=$OADP_CLOUD_PROVIDER
export BACKUP_LOCATION=$OADP_BACKUP_LOCATION
export PROW_NAMESPACE=$NAMESPACE
export NAMESPACE="openshift-adp"
export BUCKET="${PROW_NAMESPACE}-${BUCKET_NAME}"
export KUBECONFIG="/home/jenkins/.kube/config"
export OADP_TEST_FOCUS="--ginkgo.focus=${OADP_TEST_FOCUS}"
export ANSIBLE_REMOTE_TMP="/tmp/"
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
RESULTS_FILE="/alabama/cspi/e2e/junit_report.xml"
LOGS_FOLDER="/alabama/cspi/e2e/logs"

# Extract additional repository archives
mkdir -p {$OADP_GIT_DIR,$OADP_APPS_DIR,$PYCLIENT_DIR}
echo "Extract /home/jenkins/oadp-e2e-qe.tar.gz to ${OADP_GIT_DIR}"
tar -xf /home/jenkins/oadp-e2e-qe.tar.gz -C "${OADP_GIT_DIR}" --strip-components 1
echo "Extract /home/jenkins/oadp-apps-deployer.tar.gz to ${OADP_APPS_DIR}"
tar -xf /home/jenkins/oadp-apps-deployer.tar.gz -C "${OADP_APPS_DIR}" --strip-components 1
echo "Extract /home/jenkins/mtc-python-client.tar.gz to ${PYCLIENT_DIR}"
tar -xf /home/jenkins/mtc-python-client.tar.gz -C "${PYCLIENT_DIR}" --strip-components 1

# Setup /tmp/test-settings
echo "Create and populate /tmp/test-settings..."
mkdir -p /tmp/test-settings
cp "${SHARED_DIR}/credentials" /tmp/test-settings
cp "${CLUSTER_PROFILE_DIR}/.awscred" /tmp/test-settings/aws_creds
touch /tmp/test-settings/default_settings.json

# Login to the test cluster as Kubeadmin
echo "Login as Kubeadmin to the test cluster at ${API_URL}..."
mkdir -p /home/jenkins/.kube
touch /home/jenkins/.kube/config
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

# Setup Python Virtual Environment
echo "Create virtual environment and install required packages..."
python3 -m venv /alabama/venv
source /alabama/venv/bin/activate
python3 -m pip install ansible_runner
python3 -m pip install "${OADP_APPS_DIR}" --target "${OADP_GIT_DIR}/sample-applications/"
python3 -m pip install "${PYCLIENT_DIR}"

# Archive results function
function archive-results() {
    if [[ -f "${RESULTS_FILE}" ]] && [[ ! -f "${ARTIFACT_DIR}/junit_oadp_interop_results.xml" ]]; then
        echo "Copying ${RESULTS_FILE} to ${ARTIFACT_DIR}/junit_oadp_interop_results.xml..."
        cp "${RESULTS_FILE}" "${ARTIFACT_DIR}/junit_oadp_interop_results.xml"

        echo "Copying ${LOGS_FOLDER} to ${ARTIFACT_DIR}..."
        cp -r "${LOGS_FOLDER}" "${ARTIFACT_DIR}/logs"
    fi
}

# Execute tests
echo "Executing tests..."
trap archive-results SIGINT SIGTERM ERR EXIT
cd $OADP_GIT_DIR
EXTRA_GINKGO_PARAMS=$OADP_TEST_FOCUS /bin/bash /alabama/cspi/test_settings/scripts/test_runner.sh
