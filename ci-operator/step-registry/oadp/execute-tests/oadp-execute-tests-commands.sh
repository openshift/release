#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set variables needed to login to AWS
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE=$CLUSTER_PROFILE_DIR/.aws
export AWS_ACCESS_KEY_ID=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
export AWS_SECRET_ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)

# Set variables needed for test execution
export OADP_CREDS_FILE="/tmp/test-settings/credentials"
export PROVIDER="aws"
export PROW_NAMESPACE=$NAMESPACE
export NAMESPACE="openshift-adp"
export BUCKET="${PROW_NAMESPACE}-${BUCKET_NAME}"
export KUBECONFIG="/home/jenkins/.kube/config"
export ANSIBLE_REMOTE_TMP="/tmp/"
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
RESULTS_FILE="/alabama/cspi/e2e/junit_report.xml"

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

# Execute tests
echo "Executing tests..."
cd $OADP_GIT_DIR
EXTRA_GINKGO_PARAMS=--ginkgo.focus=test-upstream /bin/bash /alabama/cspi/test_settings/scripts/test_runner.sh || true

# Archive results
echo "Copying ${RESULTS_FILE} to ${ARTIFACT_DIR}/junit_oadp_interop_results.xml..."
cp "${RESULTS_FILE}" "${ARTIFACT_DIR}/junit_oadp_interop_results.xml" || true

echo "Complete..."