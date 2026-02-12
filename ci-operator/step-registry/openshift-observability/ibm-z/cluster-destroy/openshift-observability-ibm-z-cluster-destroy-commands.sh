#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp

# --- SETUP AND VARIABLES ---
SECRET_DIR="/tmp/vault/ibmz-ci-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/IPI_SSH_KEY"
SSH_KEY_PATH="/tmp/id_rsa"
OUTPUT_FILE="/tmp/deletedcluster-logs"
IP_JUMPHOST=128.168.131.205

# --- PREPARE SSH KEY ---
cp -f "$PRIVATE_KEY_FILE" "$SSH_KEY_PATH"
chmod 400 "$SSH_KEY_PATH"

# --- SSH CONFIGURATION ---
# StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null are used
# to avoid interactive prompts in the CI environment.
SSH_ARGS=" -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"

# --- REMOTE COMMAND ---
SSH_CMD=$(cat <<EOF
set -e
cd /root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning
./delete-cluster.sh
EOF
)

# --- EXECUTE SSH COMMAND ---
ssh $SSH_ARGS root@$IP_JUMPHOST "$SSH_CMD" > "$OUTPUT_FILE"

echo "Cluster deletion initiated successfully."