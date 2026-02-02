#!/bin/bash
set -euo pipefail

# Configuration
REMOTE_HOST="${REMOTE_HOST:-nvd-srv-45.nvidia.eng.rdu2.dc.redhat.com}"

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

# Prepare SSH key from Vault (add trailing newline if missing)
echo "Configuring SSH private key..."
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

# Create SSH directory if it doesn't exist
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Create SSH config based on AMD CI pattern
echo "Creating SSH configuration..."
cat > ~/.ssh/config <<EOF
Host ${REMOTE_HOST}
    User root
    IdentityFile /tmp/id_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ConnectTimeout 30
    ServerAliveInterval 10
    ServerAliveCountMax 3
    BatchMode yes

# Default settings for all hosts
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF

chmod 600 ~/.ssh/config

# Test SSH connection
echo "Testing SSH connection to ${REMOTE_HOST}..."
if ssh ${REMOTE_HOST} echo 'SSH connection successful'; then
    echo "SSH setup complete and tested successfully"
else
    echo "ERROR: Failed to connect to hypervisor ${REMOTE_HOST}"
    echo "Debug information:"
    echo "- Checking if SSH key exists:"
    ls -la /tmp/id_rsa
    echo "- Testing SSH connectivity with verbose output:"
    ssh -v ${REMOTE_HOST} echo 'test' || true
    exit 1
fi

# Export remote host for subsequent steps
echo "REMOTE_HOST=${REMOTE_HOST}" >> ${SHARED_DIR}/dpf-env
echo "SSH setup completed successfully for ${REMOTE_HOST}"