#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

SOURCE_KUBEADMIN_PASSWORD_FILE="/tmp/clusters-data/aws/mtc-aws-ipi-source/auth/kubeadmin-password"
SOURCE_KUBECONFIG="/tmp/clusters-data/aws/mtc-aws-ipi-source/auth/kubeconfig"

sleep 7200
# Extract all tar files
echo "Extracting cluster data, mtc-apps-deployer, and mtc-python-client."
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data
tar -xf /mtc-e2e-qev2/mtc-apps-deployer.tar.gz -C "${MTC_APPS_DEPLOYER_DIR}" --strip-components 1
tar -xf /mtc-e2e-qev2/mtc-python-client.tar.gz -C "${MTC_PYTHON_CLIENT_DIR}" --strip-components 1


# Install required packages
echo "Installing mtc-apps-deployer and mtc-python-client."
python3 -m pip install $MTC_APPS_DEPLOYER_DIR
python3 -m pip install $MTC_PYTHON_CLIENT_DIR

# Move the oc binary
echo "Moving oc binary to /usr/bin/oc."
cp /mtc-e2e-qev2/oc /usr/bin/oc

# Login to the cluster
echo "Logging into source cluster."
SOURCE_KUBEADMIN_PASSWORD=$(cat $SOURCE_KUBEADMIN_PASSWORD_FILE)
export KUBECONFIG=$SOURCE_KUBECONFIG
oc login -u kubeadmin -p $SOURCE_KUBEADMIN_PASSWORD
