#!/bin/bash
set -euo pipefail

# Load environment
source ${SHARED_DIR}/dpf-env
export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Setup SSH - reuse same pattern as sanity-existing
cat /var/run/dpf-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

SSH="ssh -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${REMOTE_HOST}"
SCP="scp -i /tmp/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== DPF E2E Test Suite ==="
echo "Cluster: ${CLUSTER_NAME}"
echo "Remote host: ${REMOTE_HOST}"
echo "Work directory: ${REMOTE_WORK_DIR}"

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

# Run make targets from automation repo
TEST_FAILED=0

# Run sanity tests
echo ""
echo "=== Running DPF Sanity Tests ==="
if ${SSH} "cd ${REMOTE_WORK_DIR} && make run-dpf-sanity"; then
    echo "PASSED: make run-dpf-sanity"
else
    echo "FAILED: make run-dpf-sanity"
    TEST_FAILED=1
fi

# Run verify-deployment if target exists
echo ""
echo "=== Running Deployment Verification ==="
if ${SSH} "cd ${REMOTE_WORK_DIR} && make -n verify-deployment" &>/dev/null; then
    if ${SSH} "cd ${REMOTE_WORK_DIR} && make verify-deployment"; then
        echo "PASSED: make verify-deployment"
    else
        echo "FAILED: make verify-deployment"
        TEST_FAILED=1
    fi
else
    echo "SKIPPED: verify-deployment target not available"
fi

# Run traffic-flow-tests if target exists
echo ""
echo "=== Running Traffic Flow Tests ==="
if ${SSH} "cd ${REMOTE_WORK_DIR} && make -n run-traffic-flow-tests" &>/dev/null; then
    if ${SSH} "cd ${REMOTE_WORK_DIR} && make run-traffic-flow-tests"; then
        echo "PASSED: make run-traffic-flow-tests"
    else
        echo "FAILED: make run-traffic-flow-tests"
        TEST_FAILED=1
    fi
else
    echo "SKIPPED: run-traffic-flow-tests target not available"
fi

# Collect artifacts
echo ""
echo "=== Collecting Artifacts ==="
${SCP} -r root@${REMOTE_HOST}:${REMOTE_WORK_DIR}/logs/* ${TEST_RESULTS_DIR}/ 2>/dev/null || true
oc get nodes -o wide > ${TEST_RESULTS_DIR}/nodes.txt 2>/dev/null || true
oc get pods -A > ${TEST_RESULTS_DIR}/all-pods.txt 2>/dev/null || true

echo ""
if [[ ${TEST_FAILED} -eq 1 ]]; then
    echo "E2E test suite completed with failures"
    exit 1
else
    echo "E2E test suite completed successfully"
fi
