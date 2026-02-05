#!/bin/bash
set -euo pipefail

# Load environment
source ${SHARED_DIR}/dpf-env
export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Setup SSH
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

SSH="ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${REMOTE_HOST}"
SCP="scp -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== DPF E2E Test Suite ==="
echo "Cluster: ${CLUSTER_NAME}"
echo "Remote host: ${REMOTE_HOST}"

# Create results directory
TEST_RESULTS_DIR="${ARTIFACT_DIR}/e2e-results"
mkdir -p ${TEST_RESULTS_DIR}

# Check deployment success from previous step
if [[ "${DEPLOYMENT_SUCCESS:-false}" != "true" ]]; then
    echo "ERROR: Cluster deployment was not successful, skipping tests"
    exit 1
fi

# Validate cluster connectivity
if [[ ! -f ${KUBECONFIG} ]] || ! oc get nodes &>/dev/null; then
    echo "ERROR: Cannot connect to cluster"
    exit 1
fi

echo "Cluster connectivity confirmed"

# Run e2e tests
echo ""
echo "=== Running E2E Tests ==="
${SSH} "cd ${REMOTE_WORK_DIR} && make e2e"
TEST_RESULT=$?

# Collect artifacts
echo ""
echo "=== Collecting Artifacts ==="
${SCP} -r root@${REMOTE_HOST}:${REMOTE_WORK_DIR}/logs/* ${TEST_RESULTS_DIR}/ 2>/dev/null || true

exit ${TEST_RESULT}
