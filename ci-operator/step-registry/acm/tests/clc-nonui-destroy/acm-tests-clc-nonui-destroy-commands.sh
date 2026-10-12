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

cp ${SECRETS_DIR}/clc-interop/secret-options-yaml ./options.yaml

# Set the dynamic vars based on provisioned hub cluster.
OCP_HUB_CONSOLE_URL=$(oc whoami --show-console)
export OCP_HUB_CONSOLE_URL

OCP_HUB_CLUSTER_API_URL=$(oc whoami --show-server)
export OCP_HUB_CLUSTER_API_URL

OCP_HUB_CLUSTER_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export OCP_HUB_CLUSTER_PASSWORD
# Version of spoke cluster to be provisioned.
CLC_OCP_IMAGE_VERSION=$(cat $SECRETS_DIR/clc/ocp_image_version)
export CLC_OCP_IMAGE_VERSION

CLOUD_PROVIDERS=$(cat $SECRETS_DIR/clc/ocp_cloud_providers)
export CLOUD_PROVIDERS

GH_TOKEN=$(cat $SECRETS_DIR/clc/token)
export GH_TOKEN 

echo "TEST_STAGE = $TEST_STAGE"
# run the test execution script
bash +x ./execute_clc_nonui_interop_commands.sh

cp -r reports $ARTIFACT_DIR/
