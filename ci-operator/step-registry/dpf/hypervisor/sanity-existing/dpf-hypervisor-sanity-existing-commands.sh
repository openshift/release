#!/bin/bash
set -euo pipefail

# Sanity test on EXISTING cluster - no provisioning
# Uses kubeconfig and sanity-env from Vault

REMOTE_HOST="${REMOTE_HOST:-nvd-srv-45.nvidia.eng.rdu2.dc.redhat.com}"
BUILD_ID="${BUILD_ID:-$(date +%Y%m%d-%H%M%S)}"

echo "=== DPF Sanity Test on Existing Cluster ==="
echo "Remote host: ${REMOTE_HOST}"
echo "Build ID: ${BUILD_ID}"

# Setup SSH
echo "Setting up SSH..."
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

SSH="ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${REMOTE_HOST}"
SCP="scp -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Test SSH connection
echo "Testing SSH connection..."
if ! ${SSH} echo 'SSH connection successful'; then
    echo "ERROR: Failed to connect to ${REMOTE_HOST}"
    exit 1
fi

# Create working directory on hypervisor
SANITY_DIR="/tmp/dpf-sanity-${BUILD_ID}"
echo "Creating working directory: ${SANITY_DIR}"
${SSH} "mkdir -p ${SANITY_DIR}"

# Copy repository to hypervisor (tar + ssh, rsync not available)
echo "Copying repository to hypervisor..."
tar czf - --exclude='.git' --exclude='logs' --exclude='*.log' . | \
    ${SSH} "tar xzf - -C ${SANITY_DIR}"

# Decode and copy kubeconfig from Vault
echo "Setting up kubeconfig..."
if [[ -f /var/run/dpf-ci/kubeconfig ]]; then
    cat /var/run/dpf-ci/kubeconfig | base64 -d > /tmp/kubeconfig
    ${SCP} /tmp/kubeconfig root@${REMOTE_HOST}:${SANITY_DIR}/kubeconfig
else
    echo "ERROR: kubeconfig not found in Vault"
    exit 1
fi

# Decode and copy sanity-env as .env
echo "Setting up environment (sanity-env)..."
if [[ -f /var/run/dpf-ci/sanity-env ]]; then
    cat /var/run/dpf-ci/sanity-env | base64 -d > /tmp/sanity-env
    # Add KUBECONFIG path
    echo "KUBECONFIG=${SANITY_DIR}/kubeconfig" >> /tmp/sanity-env
    ${SCP} /tmp/sanity-env root@${REMOTE_HOST}:${SANITY_DIR}/.env
else
    echo "ERROR: sanity-env not found in Vault"
    exit 1
fi

# Make scripts executable
${SSH} "find ${SANITY_DIR}/scripts -name '*.sh' -exec chmod +x {} +"

# Verify setup
echo "Verifying setup..."
${SSH} "cd ${SANITY_DIR} && ls -la .env kubeconfig"
${SSH} "cd ${SANITY_DIR} && cat .env"

# Run sanity tests
echo "=== Running DPF Sanity Tests ==="
SANITY_LOG="${SANITY_DIR}/sanity-$(date +%Y%m%d_%H%M%S).log"
TEST_RESULT=0

if ${SSH} "cd ${SANITY_DIR} && make run-dpf-sanity 2>&1 | tee ${SANITY_LOG}"; then
    echo "Sanity tests PASSED"
else
    echo "Sanity tests FAILED"
    TEST_RESULT=1
fi

# Collect artifacts
mkdir -p ${ARTIFACT_DIR}/sanity-results
${SCP} root@${REMOTE_HOST}:${SANITY_LOG} ${ARTIFACT_DIR}/sanity-results/ || echo "Could not retrieve log"

# Cleanup
echo "Cleaning up..."
${SSH} "rm -rf ${SANITY_DIR}"

if [[ ${TEST_RESULT} -eq 0 ]]; then
    echo "=== Sanity Test Completed Successfully ==="
else
    echo "=== Sanity Test Failed ==="
    exit 1
fi
