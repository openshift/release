#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

TARGET_KUBEADMIN_PASSWORD_FILE="/tmp/clusters-data/aws/mtc-aws-ipi-target/auth/kubeadmin-password"
TARGET_KUBECONFIG="/tmp/clusters-data/aws/mtc-aws-ipi-target/auth/kubeconfig"

# Move the oc binary
echo "Moving oc binary to /usr/bin/oc."
cp /mtc-e2e-qev2/oc /usr/bin/oc

# Extract all tar files
echo "Extracting cluster data, mtc-apps-deployer, and mtc-python-client."
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data
tar -xf /mtc-e2e-qev2/mtc-apps-deployer.tar.gz -C "${MTC_APPS_DEPLOYER_DIR}" --strip-components 1
tar -xf /mtc-e2e-qev2/mtc-python-client.tar.gz -C "${MTC_PYTHON_CLIENT_DIR}" --strip-components 1

# Create a virtual environment
echo "Creating Python virtual environment"
python -m venv /mtc-e2e-qev2/venv
source /mtc-e2e-qev2/venv/bin/activate

# Install required packages
echo "Installing mtc-apps-deployer and mtc-python-client."
python3 -m pip install -r $TEST_REPOSITORY_DIR/requirements.txt --ignore-installed
python3 -m pip install $MTC_APPS_DEPLOYER_DIR
python3 -m pip install $MTC_PYTHON_CLIENT_DIR

sleep 7200
# Login to the cluster
echo "Logging into source cluster."
TARGET_KUBEADMIN_PASSWORD=$(cat $TARGET_KUBEADMIN_PASSWORD_FILE)
export KUBECONFIG=$TARGET_KUBECONFIG
oc login -u kubeadmin -p $TARGET_KUBEADMIN_PASSWORD

# pytest -srA -k interopci --junit-xml=/mtc-e2e-qev2/junit-report.xml