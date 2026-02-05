#!/bin/bash
set -euo pipefail

# Load environment
source ${SHARED_DIR}/dpf-env

# Setup SSH - reuse same pattern as sanity-existing
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

SSH="ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${REMOTE_HOST}"
SCP="scp -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "Deploying OpenShift cluster with DPF on ${REMOTE_HOST}"
echo "Working directory: ${REMOTE_WORK_DIR}"
echo "Cluster name: ${CLUSTER_NAME}"

# Create logs directory for artifacts
LOGS_DIR="${ARTIFACT_DIR}/deployment-logs"
mkdir -p ${LOGS_DIR}

# Start deployment with logging
DEPLOYMENT_LOG="${REMOTE_WORK_DIR}/logs/make_all_$(date +%Y%m%d_%H%M%S).log"

echo "Starting DPF deployment with 'make all'..."
echo "Logs will be saved to: ${DEPLOYMENT_LOG}"

# Execute make all on hypervisor with comprehensive logging
if ${SSH} "cd ${REMOTE_WORK_DIR} && mkdir -p logs && make all 2>&1 | tee ${DEPLOYMENT_LOG}"; then
    echo "DPF deployment completed successfully"
    DEPLOYMENT_SUCCESS=true
else
    echo "DPF deployment failed"
    DEPLOYMENT_SUCCESS=false
fi

# Copy deployment logs back for analysis
echo "Copying deployment logs for artifact collection..."
${SCP} -r root@${REMOTE_HOST}:${REMOTE_WORK_DIR}/logs/* ${LOGS_DIR}/ || echo "Some logs could not be copied"

# Copy kubeconfig if deployment succeeded
if [[ "${DEPLOYMENT_SUCCESS}" == "true" ]]; then
    echo "Copying kubeconfig from hypervisor..."

    # Check for kubeconfig files
    if ${SSH} "cd ${REMOTE_WORK_DIR} && test -f kubeconfig"; then
        ${SCP} root@${REMOTE_HOST}:${REMOTE_WORK_DIR}/kubeconfig ${SHARED_DIR}/kubeconfig
        echo "Kubeconfig copied successfully"
    elif ${SSH} "cd ${REMOTE_WORK_DIR} && test -f ${CLUSTER_NAME}.kubeconfig"; then
        ${SCP} root@${REMOTE_HOST}:${REMOTE_WORK_DIR}/${CLUSTER_NAME}.kubeconfig ${SHARED_DIR}/kubeconfig
        echo "Kubeconfig copied successfully"
    else
        echo "WARNING: Could not find kubeconfig file"
        ${SSH} "cd ${REMOTE_WORK_DIR} && ls -la *.kubeconfig kubeconfig" || echo "No kubeconfig files found"
        DEPLOYMENT_SUCCESS=false
    fi
else
    echo "Deployment failed, skipping kubeconfig copy"
fi

# Validate cluster accessibility if kubeconfig exists
if [[ "${DEPLOYMENT_SUCCESS}" == "true" && -f ${SHARED_DIR}/kubeconfig ]]; then
    echo "Validating cluster accessibility..."
    export KUBECONFIG=${SHARED_DIR}/kubeconfig

    # Test cluster connectivity
    if oc get nodes &>/dev/null; then
        echo "Cluster is accessible via kubeconfig"

        # Get basic cluster info for artifacts
        oc get nodes > ${LOGS_DIR}/cluster-nodes.txt
        oc get co > ${LOGS_DIR}/cluster-operators.txt || echo "Could not get cluster operators"
        oc version > ${LOGS_DIR}/cluster-version.txt || echo "Could not get cluster version"

        echo "Cluster validation completed successfully"
    else
        echo "ERROR: Cannot access cluster with provided kubeconfig"
        DEPLOYMENT_SUCCESS=false
    fi
fi

# Collect hypervisor status for debugging
echo "Collecting hypervisor status for artifacts..."
${SSH} "df -h" > ${LOGS_DIR}/hypervisor-disk-usage.txt || true
${SSH} "free -h" > ${LOGS_DIR}/hypervisor-memory-usage.txt || true
${SSH} "virsh list --all" > ${LOGS_DIR}/hypervisor-vms.txt || true

# Export deployment status for test steps
echo "DEPLOYMENT_SUCCESS=${DEPLOYMENT_SUCCESS}" >> ${SHARED_DIR}/dpf-env

# Final status check
if [[ "${DEPLOYMENT_SUCCESS}" == "true" ]]; then
    echo "DPF deployment completed successfully!"
    echo "Cluster: ${CLUSTER_NAME}"
    echo "Kubeconfig available at: ${SHARED_DIR}/kubeconfig"
    echo "Ready for testing..."
else
    echo "DPF deployment failed!"
    echo "Check logs in: ${LOGS_DIR}/"
    echo "Remote logs: ${REMOTE_WORK_DIR}/logs/"
    exit 1
fi
