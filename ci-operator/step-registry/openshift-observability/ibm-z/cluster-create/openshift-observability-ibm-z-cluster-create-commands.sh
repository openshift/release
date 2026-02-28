#!/bin/bash

set -o errexit
set -o pipefail
export HOME=/tmp
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

cd /tmp

# --- SETUP AND VARIABLES ---
SECRET_DIR="/tmp/vault/ibmz-ci-creds/ssh-creds-dt"
PRIVATE_KEY_FILE="${SECRET_DIR}/IPI_SSH_KEY"
IP_JUMPHOST=128.168.131.115
CLUSTER_VARS_PATH="/root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning/cluster-vars"
SSH_KEY_PATH="/tmp/id_rsa"

# --- VERIFY KEY ---
# Check if the private key file exists
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    echo "Error: Private key file not found at $PRIVATE_KEY_FILE" >&2
    exit 1
fi


# --- PREPARE SSH KEY ---
# Copy the (read-only) secret to a writable location, then normalize it there

# Create SSH_KEY_PATH by wrapping the mounted secret with OPENSSH headers (do not modify the mounted secret)
wrapped_tmp="${SSH_KEY_PATH}.wrapped"
if grep -qE 'BEGIN .*PRIVATE KEY' "$PRIVATE_KEY_FILE" >/dev/null 2>&1; then
    # Secret already contains a header/footer — copy as-is to writable path
    cp -f "$PRIVATE_KEY_FILE" "$SSH_KEYPath" 2>/dev/null || cp -f "$PRIVATE_KEY_FILE" "$SSH_KEY_PATH"
else
    # Wrap the raw key content with BEGIN/END markers into a temporary file, then copy it
    {
      printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----"
      cat "$PRIVATE_KEY_FILE"
      printf '%s\n' "-----END OPENSSH PRIVATE KEY-----"
    } > "$wrapped_tmp"
    # copy the wrapped file into the final SSH_KEY_PATH (avoids writing to the mounted secret)
    cp -f "$wrapped_tmp" "$SSH_KEY_PATH"
    rm -f "$wrapped_tmp"
fi

# Set strict permissions for SSH
chmod 0400 "$SSH_KEY_PATH"

# Optional: quick parse check (will exit if key invalid or passphrase-protected)
if ! ssh-keygen -y -f "$SSH_KEY_PATH" >/dev/null 2>&1; then
    echo "Error: constructed private key at $SSH_KEY_PATH is invalid or requires a passphrase" >&2
    exit 1
fi

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
