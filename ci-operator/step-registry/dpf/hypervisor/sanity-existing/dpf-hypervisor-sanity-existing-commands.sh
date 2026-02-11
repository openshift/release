#!/bin/bash
set -euo pipefail

# Configuration
REMOTE_HOST="${REMOTE_HOST:-10.6.135.45}"

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

# Prepare SSH key from Vault (add trailing newline if missing)
echo "Configuring SSH private key..."
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

# Define SSH command with explicit options (don't rely on ~/.ssh/config)
SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

### DEBUG: add a ong timeout to troubleshoot from pod
## echo "Sleeping for 999999999 seconds ...."
## sleep 999999999

# Test SSH connection
echo "Testing SSH connection to ${REMOTE_HOST}..."
if ssh ${SSH_OPTS} root@${REMOTE_HOST} echo 'SSH connection successful'; then
    echo "SSH setup complete and tested successfully"
else
    echo "ERROR: Failed to connect to hypervisor ${REMOTE_HOST}"
    echo "Debug information:"
    echo "- Checking if SSH key exists:"
    ls -la /tmp/id_rsa
    echo "- Testing SSH connectivity with verbose output:"
    ssh -v ${SSH_OPTS} root@${REMOTE_HOST} echo 'test' || true
    exit 1
fi

# Export SSH settings for subsequent steps
echo "REMOTE_HOST=${REMOTE_HOST}" >> ${SHARED_DIR}/dpf-env
echo "SSH_OPTS=${SSH_OPTS}" >> ${SHARED_DIR}/dpf-env
echo "SSH setup completed successfully for ${REMOTE_HOST}"

# Run dpf-sanity-checks sanity test
if ssh $SSH_OPTS root@$REMOTE_HOST "ls -ltr; cd /root/doca8/openshift-dpf; export KUBECONFIG=/root/doca8/openshift-dpf/kubeconfig-mno; oc get dpu -A; make verify-workers; make verify-dpu-nodes; make verify-deployment; make verify-dpudeployment; make run-dpf-sanity"; then echo "Sanity Test Passed"; else echo "Sanity Test Failed"; fi
