#!/bin/bash
set -euo pipefail

REMOTE_HOST=$(cat ${CLUSTER_PROFILE_DIR}/remote-host)

echo "Setting up SSH access to DPF hypervisor: ${REMOTE_HOST}"

# Prepare SSH key from Vault (add trailing newline if missing)
cat ${CLUSTER_PROFILE_DIR}/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

SSH_OPTS="-i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"

# Start iperf3 server on bastion via podman
CONTAINER_NAME="tft-iperf3-server"
echo "Cleaning up any leftover iperf3 container on bastion..."
ssh ${SSH_OPTS} root@${REMOTE_HOST} "podman rm -f ${CONTAINER_NAME}" || true
echo "Starting iperf3 server container '${CONTAINER_NAME}' on bastion ${REMOTE_HOST}..."
ssh ${SSH_OPTS} root@${REMOTE_HOST} \
    "podman run -d --rm --name ${CONTAINER_NAME} --network host ghcr.io/ovn-kubernetes/kubernetes-traffic-flow-tests:latest iperf3 -s -p 5201"

cleanup() {
    echo "Stopping iperf3 server container on bastion..."
    ssh ${SSH_OPTS} root@${REMOTE_HOST} "podman stop ${CONTAINER_NAME}" || true
}
trap cleanup EXIT

# Use kubeconfig from load-kubeconfig step
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Copy .env to working directory
cp "${SHARED_DIR}/.env" .env

echo "Verifying cluster access..."
oc get nodes

# Select two worker-dpu nodes
TFT_SERVER_NODE=$(oc get nodes --no-headers | grep worker-dpu | awk 'NR==1 {print $1}')
TFT_CLIENT_NODE=$(oc get nodes --no-headers | grep worker-dpu | awk 'NR==2 {print $1}')

if [[ -z "${TFT_SERVER_NODE}" ]] || [[ -z "${TFT_CLIENT_NODE}" ]]; then
    echo "ERROR: Need at least 2 worker-dpu nodes, found:"
    oc get nodes --no-headers | grep worker-dpu || true
    exit 1
fi

echo "TFT_SERVER_NODE=${TFT_SERVER_NODE}"
echo "TFT_CLIENT_NODE=${TFT_CLIENT_NODE}"

export TFT_SERVER_NODE
export TFT_CLIENT_NODE
export TFT_KUBECONFIG="${SHARED_DIR}/kubeconfig"
export TFT_EXTERNAL_SERVER="${REMOTE_HOST}:5201"

echo "=== Running DPF Kubernetes Traffic Flow Tests ==="
echo "TFT_EXTERNAL_SERVER=${TFT_EXTERNAL_SERVER}"
make run-traffic-flow-tests
