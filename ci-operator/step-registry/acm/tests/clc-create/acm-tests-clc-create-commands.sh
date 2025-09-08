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

######### added for debugging purposes #########
# export DISPLAY=:99
# Xvfb :99 &
# # Xvfb :99 -screen 0 1024x768x16 2>/dev/null &

# export CYPRESS_video=false
# export CYPRESS_videoCompression=false
###############################################

export KUBECONFIG=${SHARED_DIR}/kubeconfig

cp ${SECRETS_DIR}/clc-interop/secret-options-yaml ./options.yaml

# Set the dynamic vars based on provisioned hub cluster.
CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL

CYPRESS_HUB_API_URL=$(oc whoami --show-server)
export CYPRESS_HUB_API_URL

CYPRESS_OPTIONS_HUB_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export CYPRESS_OPTIONS_HUB_PASSWORD
# Version of spoke cluster to be provisioned.
CYPRESS_CLC_OCP_IMAGE_VERSION=$(cat $SECRETS_DIR/clc/ocp_image_version)
export CYPRESS_CLC_OCP_IMAGE_VERSION

CLOUD_PROVIDERS=$(cat $SECRETS_DIR/clc/ocp_cloud_providers)
export CLOUD_PROVIDERS

# run the test execution script
bash +x ./execute_clc_interop_commands.sh

cp -r reports $ARTIFACT_DIR/
