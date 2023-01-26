#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Define the variables needed to create the MTR test configuration file. 
# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

cd tmp/clc
cp ${SECRETS_DIR}/clc/options.yaml ./
ls

# Set the dynamic vars based on provisioned hub cluster.
CYPRESS_CLC_OCP_IMAGE_VERSION=$(oc get clusterversion -o jsonpath='{.items[].status.history[].ve    rsion}{"\n"}')
export CYPRESS_CLC_OCP_IMAGE_VERSION
CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL
CYPRESS_OPTIONS_HUB_PASSWORD=$(oc get secret acm-interop-aws.kubeadmin-password)
export CYPRESS_OPTIONS_HUB_PASSWORD

sleep 600

# run the test execution script
./execute_clc_interop_commands.sh

