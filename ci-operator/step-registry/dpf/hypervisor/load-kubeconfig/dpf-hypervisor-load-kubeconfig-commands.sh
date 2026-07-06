#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

# Configuration
REMOTE_HOST="${REMOTE_HOST:-10.6.135.45}"
REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION="/root/doca8/ci/last-openshift-dpf-dir.sh"

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

# Prepare SSH key from Vault (add trailing newline if missing)
echo "Configuring SSH private key..."
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

# Define SSH command with explicit options (don't rely on ~/.ssh/config)
SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

# Test SSH connection
echo "Testing SSH connection to ${REMOTE_HOST}..."
if ssh ${SSH_OPTS} root@${REMOTE_HOST} echo 'SSH connection successful'; then
    echo "SSH setup complete and tested successfully"
else
    echo "ERROR: Failed to connect to hypervisor ${REMOTE_HOST}"
    exit 1
fi

# Find the last DPF openshift-dpf install dir on the hypervisor
echo "=== Locating last openshift-dpf install dir on hypervisor ==="
scp ${SSH_OPTS} root@${REMOTE_HOST}:${REMOTE_LAST_OPENSHIFT_DPF_DIR_LOCATION} /tmp

if [ -f /tmp/last-openshift-dpf-dir.sh ]; then
    cat /tmp/last-openshift-dpf-dir.sh
    set -a
    source /tmp/last-openshift-dpf-dir.sh
    set +a
    echo "Last openshift-dpf dir is: '${LAST_OPENSHIFT_DPF}'"
else
    echo "ERROR: Failed to find scp-ed file '/tmp/last-openshift-dpf-dir.sh'"
    exit 1
fi

# Copy the cluster kubeconfig from the last install dir on the hypervisor
echo "=== Copying kubeconfig from ${LAST_OPENSHIFT_DPF} on hypervisor ==="
scp ${SSH_OPTS} root@${REMOTE_HOST}:${LAST_OPENSHIFT_DPF}/kubeconfig.doca8 /tmp/kubeconfig.doca8

cp /tmp/kubeconfig.doca8 "${SHARED_DIR}/kubeconfig"
echo "Kubeconfig copied to \${SHARED_DIR}/kubeconfig successfully"
