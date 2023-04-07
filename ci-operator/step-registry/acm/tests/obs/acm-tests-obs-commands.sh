#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
<<<<<<< HEAD
<<<<<<< HEAD
SKIP_OCP_DEPLOY=$(cat $SECRETS_DIR/ci/skip-ocp-deploy)
=======
SKIP_OCP_DEPLOY="false"
>>>>>>> 95a2a3367bd (Vboulos add step rigistry for grc (#37587))
=======
SKIP_OCP_DEPLOY="false"
=======
SKIP_OCP_DEPLOY=$(cat $SECRETS_DIR/ci/skip-ocp-deploy)
>>>>>>> 5a5c8458267 (Complete component ref creation)
>>>>>>> 9e5dae003f9 (Complete component ref creation)
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
<<<<<<< HEAD
<<<<<<< HEAD
=======
    cp ${SECRETS_DIR}/ci/metadata $SHARED_DIR/metadata.json
>>>>>>> 95a2a3367bd (Vboulos add step rigistry for grc (#37587))
=======
    cp ${SECRETS_DIR}/ci/metadata $SHARED_DIR/metadata.json
=======
>>>>>>> 5a5c8458267 (Complete component ref creation)
>>>>>>> 9e5dae003f9 (Complete component ref creation)
fi 

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# The AWS secrets
PARAM_AWS_SECRET_ACCESS_KEY=$(cat $SECRETS_DIR/obs/aws-secret-access-key)
export PARAM_AWS_SECRET_ACCESS_KEY

PARAM_AWS_ACCESS_KEY_ID=$(cat $SECRETS_DIR/obs/aws-access-key-id)
export PARAM_AWS_ACCESS_KEY_ID

# Set the dynamic vars based on provisioned hub cluster.
OC_HUB_CLUSTER_API_URL=$(oc whoami --show-server)
export OC_HUB_CLUSTER_API_URL

# Get the base domain from the API URL
<<<<<<< HEAD
<<<<<<< HEAD
left_cut=${OC_HUB_CLUSTER_API_URL:12} # substring --> ${VAR:start_index:length} --> remove https://api.
BASE_DOMAIN=${left_cut/:6443/} # replace :6433 with empty string
# BASE_DOMAIN=$(cat $SHARED_DIR/metadata.json |jq -r '.aws.clusterDomain')
export BASE_DOMAIN

HUB_CLUSTER_NAME=${BASE_DOMAIN/.cspilp.interop.ccitredhat.com/}
# HUB_CLUSTER_NAME=$(cat $SHARED_DIR/metadata.json |jq -r '.clusterName') 
=======
=======
>>>>>>> 9e5dae003f9 (Complete component ref creation)
# left_cut=${OC_HUB_CLUSTER_API_URL:12} # substring --> ${VAR:start_index:length} --> remove https://api.
# BASE_DOMAIN=${left_cut/:6443/} # replace :6433 with empty string
BASE_DOMAIN=$(cat $SHARED_DIR/metadata.json |jq -r '.aws.clusterDomain')
export BASE_DOMAIN

# HUB_CLUSTER_NAME=${BASE_DOMAIN/.cspilp.interop.ccitredhat.com/}
HUB_CLUSTER_NAME=$(cat $SHARED_DIR/metadata.json |jq -r '.clusterName') 
<<<<<<< HEAD
>>>>>>> 95a2a3367bd (Vboulos add step rigistry for grc (#37587))
=======
=======
left_cut=${OC_HUB_CLUSTER_API_URL:12} # substring --> ${VAR:start_index:length} --> remove https://api.
BASE_DOMAIN=${left_cut/:6443/} # replace :6433 with empty string
# BASE_DOMAIN=$(cat $SHARED_DIR/metadata.json |jq -r '.aws.clusterDomain')
export BASE_DOMAIN

HUB_CLUSTER_NAME=${BASE_DOMAIN/.cspilp.interop.ccitredhat.com/}
# HUB_CLUSTER_NAME=$(cat $SHARED_DIR/metadata.json |jq -r '.clusterName') 
>>>>>>> 5a5c8458267 (Complete component ref creation)
>>>>>>> 9e5dae003f9 (Complete component ref creation)
export HUB_CLUSTER_NAME

OC_HUB_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export OC_HUB_CLUSTER_PASS

# Set the dynamic vars needed to execute the Observability scenarios on the managed clusters
MANAGED_CLUSTER_NAME=$(cat $SHARED_DIR/managed.cluster.name)
export MANAGED_CLUSTER_NAME

MANAGED_CLUSTER_BASE_DOMAIN=$(cat $SHARED_DIR/managed.cluster.base.domain)
export MANAGED_CLUSTER_BASE_DOMAIN

MANAGED_CLUSTER_USER=$(cat $SHARED_DIR/managed.cluster.username)
export MANAGED_CLUSTER_USER

MANAGED_CLUSTER_PASS=$(cat $SHARED_DIR/managed.cluster.password)
export MANAGED_CLUSTER_PASS

MANAGED_CLUSTER_API_URL=$(cat $SHARED_DIR/managed.cluster.api.url)
export MANAGED_CLUSTER_API_URL

# Create a .kube directory inside the alabama dir
mkdir -p /alabama/.kube

# Copy Kubeconfig file to the directory where Obs is looking it up
cp ${SHARED_DIR}/kubeconfig ~/.kube/config

# run the test execution script
bash +x ./execute_obs_interop_commands.sh

# Copy the test cases results to an external directory
<<<<<<< HEAD
<<<<<<< HEAD
cp -r /tmp/obs/tests/pkg/tests $ARTIFACT_DIR/
=======
cp -r tests/pkg/tests $ARTIFACT_DIR/
>>>>>>> 95a2a3367bd (Vboulos add step rigistry for grc (#37587))
=======
cp -r tests/pkg/tests $ARTIFACT_DIR/
=======
cp -r /tmp/obs/tests/pkg/tests $ARTIFACT_DIR/
>>>>>>> 5a5c8458267 (Complete component ref creation)
>>>>>>> 9e5dae003f9 (Complete component ref creation)
