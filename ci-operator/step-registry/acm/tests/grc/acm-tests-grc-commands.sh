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

# Set the dynamic vars based on provisioned hub cluster.
OC_CLUSTER_URL=$(oc whoami --show-server)
export OC_CLUSTER_URL
CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL
OC_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export OC_CLUSTER_PASS
RBAC_PASS=$(cat $SECRETS_DIR/grc/rbac-pass)
export RBAC_PASS

# run the test execution script
./execute_grc_interop_commands.sh

# Copy the test cases results to an external directory
cp -r test-output/cypress $ARTIFACT_DIR/