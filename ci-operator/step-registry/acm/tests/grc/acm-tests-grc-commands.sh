#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
# SECRETS_DIR="/tmp/secrets"


# Set the dynamic vars based on provisioned hub cluster.
OC_CLUSTER_URL=$(oc whoami --show-server)
export OC_CLUSTER_URL
CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL
OC_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export OC_CLUSTER_PASS

# run the test execution script
./execute_grc_interop_commands.sh

# Copy the test cases results to an external directory
cp -r test-output/cypress $ARTIFACT_DIR/