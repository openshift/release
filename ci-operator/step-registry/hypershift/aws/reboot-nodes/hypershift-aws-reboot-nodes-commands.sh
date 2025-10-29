#!/bin/bash

set -euo pipefail

echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Rebooting AWS management cluster nodes"
echo "=========================================================================="

# Configure AWS credentials
export AWS_SHARED_CREDENTIALS_FILE=/etc/hypershift-pool-aws-credentials/.awscred
export AWS_REGION=${HYPERSHIFT_AWS_REGION:-us-east-1}

echo "Using kubeconfig: ${KUBECONFIG}"
echo "AWS Region: ${AWS_REGION}"

# Get all worker nodes
echo "Getting list of worker nodes..."
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name)
NODE_COUNT=$(echo "${WORKER_NODES}" | wc -l)

if [ "${NODE_COUNT}" -eq 0 ]; then
    echo "ERROR: No worker nodes found in the management cluster"
    exit 1
fi

echo "Found ${NODE_COUNT} worker nodes to reboot"

# Get AWS instance IDs for all worker nodes
INSTANCE_IDS=()
for NODE in ${WORKER_NODES}; do
    echo "Getting AWS instance ID for node: ${NODE}"
    INSTANCE_ID=$(oc get node "${NODE}" -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)
    if [ -z "${INSTANCE_ID}" ]; then
        echo "WARNING: Could not get instance ID for node ${NODE}, skipping"
        continue
    fi
    echo "  Node ${NODE} -> Instance ${INSTANCE_ID}"
    INSTANCE_IDS+=("${INSTANCE_ID}")
done

if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
    echo "ERROR: Could not find any AWS instance IDs"
    exit 1
fi

echo ""
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Triggering reboot for ${#INSTANCE_IDS[@]} instances"
echo "=========================================================================="

# Reboot all instances
for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
    echo "Rebooting instance: ${INSTANCE_ID}"
    aws ec2 reboot-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}" || {
        echo "WARNING: Failed to reboot instance ${INSTANCE_ID}"
    }
done

echo ""
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Waiting ${REBOOT_WAIT_TIME}s for nodes to start rebooting..."
echo "=========================================================================="
sleep "${REBOOT_WAIT_TIME}"

echo ""
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Waiting for nodes to recover (max ${RECOVERY_WAIT_TIME}s)..."
echo "=========================================================================="

# Wait for nodes to become Ready again
START_TIME=$(date +%s)
TIMEOUT=${RECOVERY_WAIT_TIME}

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
        echo "ERROR: Timeout waiting for nodes to recover after ${TIMEOUT}s"
        echo "Current node status:"
        oc get nodes -l node-role.kubernetes.io/worker
        exit 1
    fi

    # Check if all nodes are Ready
    NOT_READY=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | grep -v " Ready " | wc -l || true)

    if [ "${NOT_READY}" -eq 0 ]; then
        echo "$(date --rfc-3339=seconds) All nodes are Ready!"
        break
    fi

    echo "$(date --rfc-3339=seconds) Waiting for ${NOT_READY} node(s) to become Ready... (${ELAPSED}s / ${TIMEOUT}s)"
    sleep 30
done

echo ""
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Node reboot completed successfully"
echo "=========================================================================="
oc get nodes -l node-role.kubernetes.io/worker

echo ""
echo "Nodes have successfully rebooted and recovered!"
