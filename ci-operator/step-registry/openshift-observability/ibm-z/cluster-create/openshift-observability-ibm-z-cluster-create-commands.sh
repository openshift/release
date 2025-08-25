#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
pwd

# --- SETUP AND VARIABLES ---
SECRET_DIR="/tmp/vault/ibmz-ci-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/IPI_SSH_KEY"
KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"
IP_JUMPHOST=128.168.131.205
CLUSTER_VARS_PATH="/root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning/cluster-vars"
SSH_KEY_PATH="/tmp/id_rsa"

# --- TROUBLESHOOTING STEP 1: VERIFY KEY ---
echo "--- Troubleshooting Step 1: Verifying the private key ---"
# Check if the private key file exists
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    echo "Error: Private key file not found at $PRIVATE_KEY_FILE" >&2
    exit 1
fi

# Attempt to print the public key. This will fail if the private key is corrupt.
echo "Successfully found private key. Here's its public key:"
ssh-keygen -y -f "$PRIVATE_KEY_FILE"
echo "---"

# --- PREPARE SSH KEY ---
cp -f "$PRIVATE_KEY_FILE" "$SSH_KEY_PATH"
chmod 400 "$SSH_KEY_PATH"

# --- TROUBLESHOOTING STEP 2: VERBOSE SSH LOGGING ---
# Use DEBUG level logging to get maximum detail on the authentication failure.
# The 'StrictHostKeyChecking=no' and 'UserKnownHostsFile=/dev/null' are kept
# to avoid interactive prompts in the CI environment.
SSH_ARGS=" -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o LogLevel=DEBUG -o UserKnownHostsFile=/dev/null"
echo "--- Troubleshooting Step 2: Running SSH with verbose logging ---"

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

# --- EXECUTE AND LOG ---
# The output is redirected to a temporary file to separate SSH debug logs from script output.
TEMP_LOG="/tmp/ssh-output-log"
if ! ssh $SSH_ARGS root@$IP_JUMPHOST "$SSH_CMD" 2> "$TEMP_LOG"; then
    echo "--- SSH Command Failed ---"
    echo "Here are the full SSH debug logs:"
    cat "$TEMP_LOG"
    exit 1
fi
rm -f "$TEMP_LOG"

echo "SSH command succeeded."

# --- ADDITIONAL STEPS ---
# Add back the kubectl installation and usage steps if you need them.
# KUBECONFIG="$KUBECONFIG_FILE" ./kubectl get nodes
