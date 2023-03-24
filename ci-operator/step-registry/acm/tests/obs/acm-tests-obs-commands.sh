#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# The AWS secrets
PARAM_AWS_SECRET_ACCESS_KEY=$(cat $SECRETS_DIR/obs/aws-secret-access-key)
export PARAM_AWS_SECRET_ACCESS_KEY

PARAM_AWS_ACCESS_KEY_ID=$(cat $SECRETS_DIR/obs/aws-access-key-id)
export PARAM_AWS_ACCESS_KEY_ID

# Set the dynamic vars based on provisioned hub cluster.
OC_HUB_CLUSTER_API_URL=$(oc whoami --show-server)
export OC_HUB_CLUSTER_API_URL

# Get the base domain from the API URL
left_cut=echo ${OC_HUB_CLUSTER_API_URL:12} # substring --> ${VAR:start_index:length} --> remove https://api.
BASE_DOMAIN=$(echo $left_cut | sed "s/:6443//") # replace :6433 with empty string
export BASE_DOMAIN

HUB_CLUSTER_NAME=echo $(echo $BASE_DOMAIN | sed "s/aws.interop.ccitredhat.com//")
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


# run the test execution script
./execute_obs_interop_commands.sh

# Copy the test cases results to an external directory
cp -r tests/pkg/tests $ARTIFACT_DIR/
