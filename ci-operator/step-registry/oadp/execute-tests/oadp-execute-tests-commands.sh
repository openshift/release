#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set varaibles needed to login to AWS
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE=$CLUSTER_PROFILE_DIR/.aws
export AWS_ACCESS_KEY_ID=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
export AWS_SECRET_ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)

sleep 3600

# Create S3 Bucket to Use for Testing
/bin/bash /home/jenkins/oadp-qe-automation/backup-locations/aws-s3/deploy.sh $BUCKET_NAME > /dev/null 2>&1

# Set the API_URL value using the $SHARED_DIR/console.url file
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"

# Install pip and setup virtual environment
python3 -m pip install pip --upgrade
python3 -m venv /alabama/venv
source /alabama/venv/bin/activate
pip install ansible_runner

# Create required directories
readonly OADP_GIT_DIR="/alabama/cspi"
readonly OADP_APPS_DIR="/alabama/oadpApps"
readonly PYCLIENT_DIR="/alabama/pyclient"

mkdir -p "${OADP_GIT_DIR}"
mkdir -p "${OADP_APPS_DIR}"
mkdir -p "${PYCLIENT_DIR}"
mkdir -p /tmp/test-settings
touch /tmp/test-settings/default_settings.json
touch /tmp/kubeconfig

echo "Annotate oadp namespace"
oc annotate --overwrite namespace/openshift-adp volsync.backube/privileged-movers='true'

echo "AWS info"
cp "${CLUSTER_PROFILE_DIR}/.awscred" /tmp/test-settings/aws_creds
echo "End of AWS info"

# Extract Additional Repositories
echo "Extract oadp-e2e-qe"
tar -xf /oadp-e2e-qe.tar.gz -C "${OADP_GIT_DIR}" --strip-components 1
echo "Extract appsdeployer"
tar -xf /oadp-apps-deployer.tar.gz -C "${OADP_APPS_DIR}" --strip-components 1
echo "Extract pyclient"
tar -xf /mtc-python-client.tar.gz -C "${PYCLIENT_DIR}" --strip-components 1

echo "Install ${OADP_APPS_DIR}"
python3 -m pip install "${OADP_APPS_DIR}" --target "${OADP_GIT_DIR}/sample-applications/"

echo "Install ${PYCLIENT_DIR}"
python3 -m pip install "${PYCLIENT_DIR}"

echo "chdir to OADP_GIT_DIR"
cd $OADP_GIT_DIR

export ANSIBLE_REMOTE_TMP=/tmp/

# echo "sleep"
# sleep 3600
# Set KUBECONFIG to /tmp/kubeconfig
export KUBECONFIG="/tmp/kubeconfig"
# Login as kubeadmin to the test cluster
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

echo "Run tests from CLI"
NAMESPACE=openshift-adp EXTRA_GINKGO_PARAMS=--ginkgo.focus=test-upstream bash /alabama/cspi/test_settings/scripts/test_runner.sh 
#NAMESPACE=openshift-adp bash /alabama/cspi/test_settings/scripts/test_runner.sh 

ls -laht /alabama/cspi/output_files

echo "finished"

/bin/bash /home/jenkins/oadp-qe-automation/backup-locations/aws-s3/destroy.sh $BUCKET_NAME > /dev/null 2>&1
