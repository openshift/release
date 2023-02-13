#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

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
<<<<<<< HEAD
<<<<<<< HEAD

<<<<<<< HEAD
cp -r reports/ocp_interop $ARTIFACT_DIR/
=======
cp -r reports $ARTIFACT_DIR/
>>>>>>> a345f75ee0c ([LPTOCPCI-58] use clc image as base image, add clc destroy step)
=======
>>>>>>> 54958af119f (Add ascerra dir to test clc image from fork.)
=======

cp -r reports/destroy $ARTIFACT_DIR/
>>>>>>> d61847d4237 (fix mch status check, update destroy variable)
