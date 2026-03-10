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
# Check if the private key file exists and is readable
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    echo "Error: Private key file not found at $PRIVATE_KEY_FILE" >&2
    exit 1
fi
if [[ ! -r "$PRIVATE_KEY_FILE" ]]; then
    echo "Error: Private key file is not readable: $PRIVATE_KEY_FILE" >&2
    exit 1
fi



# --- PREPARE SSH KEY ---
# Copy the (read-only) secret to a writable location
# (removed wrapped_tmp usage)

cp -f "$PRIVATE_KEY_FILE" "$SSH_KEY_PATH" || { echo "Error: failed to copy $PRIVATE_KEY_FILE to $SSH_KEY_PATH" >&2; exit 1; }

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "Error: SSH key not found at $SSH_KEY_PATH" >&2
    exit 1
fi

# Set strict permissions for SSH (600 is safe and commonly used)
chmod 0600 "$SSH_KEY_PATH"

# Validate private key (if ssh-keygen exists)
if command -v ssh-keygen >/dev/null 2>&1; then
    if ! ssh-keygen -y -f "$SSH_KEY_PATH" >/dev/null 2>&1; then
        echo "Error: private key at $SSH_KEY_PATH is invalid or requires a passphrase" >&2
        exit 1
    fi
fi




chmod 0600 "$SSH_KEY_PATH"
# --- SSH CONFIGURATION ---
# Use a bash array to avoid word-splitting problems and force only this identity
SSH_ARGS=( -i "$SSH_KEY_PATH" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null )

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
} >> "${CLUSTER_VARS_PATH}"

cd /root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning
./create-cluster.sh
EOF
)

# --- EXECUTE SSH COMMAND ---
# Ensure ssh binary exists
if ! command -v ssh >/dev/null 2>&1; then
    echo "Error: ssh client is not installed" >&2
    exit 1
fi

# Try normal run; if it fails, show a verbose retry to help debugging
if ! ssh "${SSH_ARGS[@]}" "root@${IP_JUMPHOST}" "$SSH_CMD"; then
    echo "SSH failed, retrying with verbose output for debug:" >&2
    ssh -vvv "${SSH_ARGS[@]}" "root@${IP_JUMPHOST}" "$SSH_CMD" || {
        echo "SSH failed after verbose attempt" >&2
        exit 1
    }
fi

echo "Cluster creation initiated successfully."
# ...existing code...