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

# ...existing code...
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
# ...existing code...


# --- PREPARE SSH KEY ---
# Copy the (read-only) secret to a writable location, then normalize it there
wrapped_tmp="${SSH_KEY_PATH}.wrapped"
# ensure wrapped_tmp is removed on exit
# trap 'rm -f "$wrapped_tmp"' EXIT

if grep -qE 'BEGIN .*PRIVATE KEY' "$PRIVATE_KEY_FILE" >/dev/null 2>&1; then
    # Secret already contains a header/footer — copy as-is to writable path
    cp -f "$PRIVATE_KEY_FILE" "$SSH_KEY_PATH"
else
    # Wrap the raw key content with BEGIN/END markers into a temporary file, then copy it
    {
      printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----"
      cat "$PRIVATE_KEY_FILE"
      printf '%s\n' "-----END OPENSSH PRIVATE KEY-----"
    } > "$wrapped_tmp"
    # copy the wrapped file into the final SSH_KEY_PATH (avoids writing to the mounted secret)
    cp -f "$wrapped_tmp" "$SSH_KEY_PATH"
    # explicit cleanup instead of trap (avoids using trap which requires grace_period)
    rm -f "$wrapped_tmp"
fi
# ...existing code...

# --- SSH CONFIGURATION ---
# Use a bash array to avoid word-splitting problems and force only this identity
SSH_ARGS=( -i "$SSH_KEY_PATH" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null )

# --- REMOTE COMMAND ---
# Note: The variables CLUSTER_VERSION, CLUSTER_NAME, and PULL_SECRET_FILE
# must be set in the environment for this to work.
SSH_CMD=$(cat <<'EOF'
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