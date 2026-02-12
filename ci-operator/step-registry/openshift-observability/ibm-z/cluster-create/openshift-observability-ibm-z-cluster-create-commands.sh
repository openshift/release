#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp

# --- SETUP AND VARIABLES ---
SECRET_DIR="/tmp/vault/ibmz-ci-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/IPI_SSH_KEY"
IP_JUMPHOST=128.168.131.205
CLUSTER_VARS_PATH="/root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning/cluster-vars"
SSH_KEY_PATH="/tmp/id_rsa"

# --- VERIFY KEY ---
# Check if the private key file exists
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    echo "Error: Private key file not found at $PRIVATE_KEY_FILE" >&2
    exit 1
fi

# --- PREPARE SSH KEY ---
cp -f "$PRIVATE_KEY_FILE" "$SSH_KEY_PATH"
chmod 400 "$SSH_KEY_PATH"

# --- SSH CONFIGURATION ---
# StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null are used
# to avoid interactive prompts in the CI environment.
SSH_ARGS=" -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"

# --- REMOTE COMMAND ---
# Note: The variables CLUSTER_VERSION, CLUSTER_NAME, and PULL_SECRET_FILE
# must be set in the environment for this to work.
SSH_CMD=$(cat <<EOF
set -e
# Append values directly to cluster-vars
{
  echo "CLUSTER_VERSION='${CLUSTER_VERSION}'"
  echo "CLUSTER_NAME='${CLUSTER_NAME}'"
  echo "PULL_SECRET_FILE='${PULL_SECRET_FILE}'"
} >> "$CLUSTER_VARS_PATH"

cd /root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning
./create-cluster.sh
EOF
)

# --- EXECUTE SSH COMMAND ---
ssh $SSH_ARGS root@$IP_JUMPHOST "$SSH_CMD"

echo "Cluster creation initiated successfully."