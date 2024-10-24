#!/bin/bash
set -o nounset
# set -o errexit
set -o pipefail

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
SKIP_OCP_DEPLOY="false"
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
    cp ${SECRETS_DIR}/ci/metadata $SHARED_DIR/metadata.json
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

# HUB_CLUSTER_NAME=${BASE_DOMAIN/.cspilp.interop.ccitredhat.com/}
HUB_CLUSTER_NAME=$(cat $SHARED_DIR/metadata.json |jq -r '.clusterName') 
export HUB_CLUSTER_NAME

OC_HUB_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export OC_HUB_CLUSTER_PASS

set +x
   oc login ${OC_HUB_CLUSTER_API_URL} --insecure-skip-tls-verify=true -u kubeadmin -p ${OC_HUB_CLUSTER_PASS}
set -x

# Get the base domain from the API URL
# left_cut=${OC_HUB_CLUSTER_API_URL:12} # substring --> ${VAR:start_index:length} --> remove https://api.
# BASE_DOMAIN=${left_cut/:6443/} # replace :6433 with empty string
metadata=$(cat $SHARED_DIR/metadata.json)
echo $metadata

# BASE_DOMAIN=$(cat $SHARED_DIR/metadata.json |jq -r '.aws.clusterDomain')
BASE_DOMAIN=$(oc get ingress.config.openshift.io/cluster -ojson | jq -r '.spec.domain')
echo $BASE_DOMAIN
export BASE_DOMAIN

# Set the dynamic vars needed to execute the Observability scenarios on the managed clusters
# MANAGED_CLUSTER_NAME=$(cat $SHARED_DIR/managed.cluster.name)
# export MANAGED_CLUSTER_NAME

# MANAGED_CLUSTER_BASE_DOMAIN=$(cat $SHARED_DIR/managed.cluster.base.domain)
# export MANAGED_CLUSTER_BASE_DOMAIN

# MANAGED_CLUSTER_USER=$(cat $SHARED_DIR/managed.cluster.username)
# export MANAGED_CLUSTER_USER

# MANAGED_CLUSTER_PASS=$(cat $SHARED_DIR/managed.cluster.password)
# export MANAGED_CLUSTER_PASS

# MANAGED_CLUSTER_API_URL=$(cat $SHARED_DIR/managed.cluster.api.url)
# export MANAGED_CLUSTER_API_URL

# Create a .kube directory inside the alabama dir
mkdir -p /alabama/.kube

# Copy Kubeconfig file to the directory where Obs is looking it up
cp ${SHARED_DIR}/kubeconfig ~/.kube/config

# run the test execution script
bash +x ./execute_obs_interop_commands.sh || :

# Copy the test cases results to an external directory
cp -r tests/pkg/tests $ARTIFACT_DIR/
