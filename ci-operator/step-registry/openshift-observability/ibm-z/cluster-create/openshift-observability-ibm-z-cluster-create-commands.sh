#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

export HOME=${HOME:-/tmp}
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

cd /tmp

# --- SETUP AND VARIABLES ---
SECRET_DIR="/tmp/vault/ibmz-ci-creds/ssh-creds-dt"
PRIVATE_KEY_FILE="${SECRET_DIR}/IPI_SSH_KEY"
IP_JUMPHOST="128.168.131.115"
SSH_USER="${SSH_USER:-root}"
CLUSTER_VARS_PATH="/root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning/cluster-vars"
SSH_KEY_PATH="/tmp/id_rsa"

# Required environment variables
: "${CLUSTER_VERSION:?CLUSTER_VERSION must be set}"
: "${CLUSTER_NAME:?CLUSTER_NAME must be set}"
: "${PULL_SECRET_FILE:?PULL_SECRET_FILE must be set}"

# --- VERIFY KEY SOURCE ---
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    echo "Error: Private key file not found at $PRIVATE_KEY_FILE" >&2
    exit 1
fi

if [[ ! -r "$PRIVATE_KEY_FILE" ]]; then
    echo "Error: Private key file is not readable: $PRIVATE_KEY_FILE" >&2
    exit 1
fi

# --- PREPARE SSH KEY ---
echo "Preparing SSH key..."

# set strict permissions
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 "$SSH_KEY_PATH"

# ensure key file exists and is non-empty
if [[ ! -s "$SSH_KEY_PATH" ]]; then
    echo "Error: SSH key was not created at $SSH_KEY_PATH" >&2
    exit 1
fi

# --- DEBUG: print SSH key file info and contents (no ssh-keygen) ---
echo "SSH key file info:"
ls -l "$SSH_KEY_PATH" || true
echo "SSH key raw contents (be careful with secrets):"
sed -n '1,200p' "$SSH_KEY_PATH" || true



# --- SSH CONFIGURATION ---
SSH_ARGS=(
  -i "$SSH_KEY_PATH"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR
)

# --- REMOTE COMMAND ---
SSH_CMD=$(cat <<EOF
set -e
mkdir -p "$(dirname "${CLUSTER_VARS_PATH}")"
cat > "${CLUSTER_VARS_PATH}" <<EOV
CLUSTER_VERSION='${CLUSTER_VERSION}'
CLUSTER_NAME='${CLUSTER_NAME}'
PULL_SECRET_FILE='${PULL_SECRET_FILE}'
EOV

cd /root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning
./create-cluster.sh
EOF
)

# --- VERIFY SSH CLIENT ---
if ! command -v ssh >/dev/null 2>&1; then
    echo "Error: ssh client is not installed" >&2
    exit 1
fi

# --- EXECUTE SSH COMMAND ---
echo "Connecting to ${SSH_USER}@${IP_JUMPHOST} and starting cluster creation..."
if ! ssh "${SSH_ARGS[@]}" "${SSH_USER}@${IP_JUMPHOST}" "$SSH_CMD"; then
    echo "SSH failed, retrying with verbose output for debugging..." >&2
    ssh -vvv "${SSH_ARGS[@]}" "${SSH_USER}@${IP_JUMPHOST}" "$SSH_CMD" || {
        echo "SSH failed after verbose attempt" >&2
        exit 1
    }
fi

echo "Cluster creation initiated successfully."
```// filepath: