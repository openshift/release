#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
SKIP_OCP_DEPLOY="false"
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
fi   

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Set the dynamic vars based on provisioned hub cluster.
HUB_OCP_API_URL=$(oc whoami --show-server)
export HUB_OCP_API_URL
HUB_OCP_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export HUB_OCP_PASSWORD

# run the test execution script
./fetch_clusters_commands.sh

oc get policies -n policies

if [ -s /tmp/ci/managed.cluster.name ] && ! grep -q "null" /tmp/ci/managed.cluster.name; then
    echo "managed.cluster.name file was found saving as artifact."
    cp -r /tmp/ci/managed.cluster.name $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.base.domain $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.api.url $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.username $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.password $SHARED_DIR/
else
    echo "managed.cluster.name file is empty, missing, or it contains null."
    echo "Failed to fetch managed clusters, killing job."
    exit 1
fi
