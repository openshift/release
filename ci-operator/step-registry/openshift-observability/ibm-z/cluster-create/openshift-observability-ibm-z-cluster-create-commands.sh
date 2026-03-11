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

# If the secret already contains a header, copy it; otherwise reconstruct an OpenSSH key
if grep -qE 'BEGIN .*PRIVATE KEY' "$PRIVATE_KEY_FILE"; then
    echo "Key already contains a header/footer; copying to $SSH_KEY_PATH"
    cp -f "$PRIVATE_KEY_FILE" "$SSH_KEY_PATH"
else
    echo "Key missing header/footer; reconstructing OpenSSH format at $SSH_KEY_PATH"
    {
        printf '%s\n' "-----BEGIN OPENSSH PRIVATE KEY-----"
        cat "$PRIVATE_KEY_FILE"
        printf '%s\n' "-----END OPENSSH PRIVATE KEY-----"
    } > "$SSH_KEY_PATH"
fi

# ensure key file exists and is non-empty
if [[ ! -s "$SSH_KEY_PATH" ]]; then
    echo "Error: SSH key was not created at $SSH_KEY_PATH" >&2
    exit 1
fi

# set strict permissions
chmod 600 "$SSH_KEY_PATH"

# --- VALIDATE PRIVATE KEY (require ssh-keygen in CI) ---
if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "Error: ssh-keygen is required for key validation but not found" >&2
    exit 1
fi

if ! ssh-keygen -y -f "$SSH_KEY_PATH" >/dev/null 2>&1; then
    echo "Error: private key at $SSH_KEY_PATH is invalid or requires a passphrase" >&2
    exit 1
fi

# --- DEBUG INFO: show created key, derived public key and fingerprint ---
echo "SSH key created at $SSH_KEY_PATH:"
ls -l "$SSH_KEY_PATH" || true

if ssh-keygen -y -f "$SSH_KEY_PATH" > "${SSH_KEY_PATH}.pub" 2>/dev/null; then
    echo "Derived public key:"
    cat "${SSH_KEY_PATH}.pub"
    echo "Private key fingerprint:"
    ssh-keygen -lf "$SSH_KEY_PATH" || true
else
    echo "Warning: failed to derive public key from $SSH_KEY_PATH" >&2
fi

# Quick non-interactive auth probe (no password fallback)
echo "Probing SSH auth to ${SSH_USER}@${IP_JUMPHOST}..."
if ssh -o BatchMode=yes -i "$SSH_KEY_PATH" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${IP_JUMPHOST}" 'echo AUTH_OK' >/tmp/ssh_probe.out 2>&1; then
    echo "Auth probe succeeded"
else
    echo "Auth probe failed; SSH verbose output below:" >&2
    cat /tmp/ssh_probe.out || true
    echo "Retrying verbose SSH for debug (will not retry cluster creation)..." >&2
    ssh -vvv -o BatchMode=yes -i "$SSH_KEY_PATH" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${IP_JUMPHOST}" || true
    echo "Ensure the derived public key above is present in ${SSH_USER}@${IP_JUMPHOST}:/home/${SSH_USER}/.ssh/authorized_keys or /root/.ssh/authorized_keys and permissions are 700/600."
    exit 1
fi

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