#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
<<<<<<< HEAD
<<<<<<< HEAD
# SKIP_OCP_DEPLOY=$(cat $SECRETS_DIR/ci/skip-ocp-deploy)
# if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
#     echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
#     cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
#     cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
# fi 
=======
=======
>>>>>>> 9e5dae003f9 (Complete component ref creation)
SKIP_OCP_DEPLOY="false"
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
fi 
<<<<<<< HEAD
>>>>>>> 95a2a3367bd (Vboulos add step rigistry for grc (#37587))
=======
=======
# SKIP_OCP_DEPLOY=$(cat $SECRETS_DIR/ci/skip-ocp-deploy)
# if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
#     echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
#     cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
#     cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
# fi 
>>>>>>> 5a5c8458267 (Complete component ref creation)
>>>>>>> 9e5dae003f9 (Complete component ref creation)

export KUBECONFIG=${SHARED_DIR}/kubeconfig

cp ${SECRETS_DIR}/clc/secret-options-yaml ./options.yaml

# Set the dynamic vars based on provisioned hub cluster.
CYPRESS_CLC_OCP_IMAGE_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | sed 's/[^0-9.]*\([0-9.]*\).*/\1/')
export CYPRESS_CLC_OCP_IMAGE_VERSION
CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL
CYPRESS_OPTIONS_HUB_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export CYPRESS_OPTIONS_HUB_PASSWORD

# run the test execution script
./execute_clc_interop_commands.sh

cp -r reports $ARTIFACT_DIR/
