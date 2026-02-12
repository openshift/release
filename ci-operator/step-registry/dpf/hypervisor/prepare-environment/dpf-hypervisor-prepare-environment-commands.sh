#!/bin/bash
set -euo pipefail

# Load environment
source ${SHARED_DIR}/dpf-env

echo "Preparing DPF testing environment on ${REMOTE_HOST}"

# Create unique working directory
WORK_DIR="dpf-ci-$(date +%Y%m%d-%H%M%S)-$$"
REMOTE_WORK_DIR="/tmp/${WORK_DIR}"

echo "Creating working directory: ${REMOTE_WORK_DIR}"
ssh ${REMOTE_HOST} "mkdir -p ${REMOTE_WORK_DIR}"

# Copy repository content to hypervisor
echo "Copying DPF automation repository to hypervisor..."
tar -czf - --exclude='.git' --exclude='logs' --exclude='*.log' . | \
    ssh ${REMOTE_HOST} "cd ${REMOTE_WORK_DIR} && tar -xzf -"

# Prepare .env configuration from Vault
echo "Setting up environment configuration..."
cat /var/run/dpf-ci/env | base64 -d > /tmp/dpf-ci.env

# Generate dynamic cluster name for CI
CLUSTER_NAME="dpf-ci-$(date +%Y%m%d-%H%M%S)"
sed -i "s/CLUSTER_NAME=.*/CLUSTER_NAME=${CLUSTER_NAME}/" /tmp/dpf-ci.env

# Copy .env to hypervisor
scp /tmp/dpf-ci.env ${REMOTE_HOST}:${REMOTE_WORK_DIR}/.env

# Setup pull secrets
echo "Setting up pull secrets..."

# Process OpenShift pull secret
if [[ -f /var/run/dpf-ci/openshift-pull-secret ]]; then
    cat /var/run/dpf-ci/openshift-pull-secret | base64 -d > /tmp/openshift_pull.json
    scp /tmp/openshift_pull.json ${REMOTE_HOST}:${REMOTE_WORK_DIR}/
else
    echo "ERROR: OpenShift pull secret not found in Vault"
    exit 1
fi

# Process DPF pull secret
if [[ -f /var/run/dpf-ci/dpf-pull-secret ]]; then
    cat /var/run/dpf-ci/dpf-pull-secret | base64 -d > /tmp/pull-secret.txt
    scp /tmp/pull-secret.txt ${REMOTE_HOST}:${REMOTE_WORK_DIR}/
else
    echo "ERROR: DPF pull secret not found in Vault"
    exit 1
fi

# Make scripts executable
echo "Making scripts executable..."
ssh ${REMOTE_HOST} "find ${REMOTE_WORK_DIR}/scripts -name '*.sh' -exec chmod +x {} +"

# Validate environment setup
echo "Validating environment setup..."
ssh ${REMOTE_HOST} "cd ${REMOTE_WORK_DIR} && ls -la .env openshift_pull.json pull-secret.txt"

# Check required tools on hypervisor
echo "Checking required tools on hypervisor..."
ssh ${REMOTE_HOST} "which make oc aicli virsh" || {
    echo "ERROR: Missing required tools on hypervisor"
    exit 1
}

# Check libvirt service
echo "Checking libvirt service status..."
ssh ${REMOTE_HOST} "systemctl is-active libvirtd" || {
    echo "ERROR: libvirtd service not running on hypervisor"
    exit 1
}

# Export working directory for subsequent steps
echo "REMOTE_WORK_DIR=${REMOTE_WORK_DIR}" >> ${SHARED_DIR}/dpf-env
echo "CLUSTER_NAME=${CLUSTER_NAME}" >> ${SHARED_DIR}/dpf-env

echo "Environment prepared successfully on ${REMOTE_HOST}"
echo "Working directory: ${REMOTE_WORK_DIR}"
echo "Cluster name: ${CLUSTER_NAME}"