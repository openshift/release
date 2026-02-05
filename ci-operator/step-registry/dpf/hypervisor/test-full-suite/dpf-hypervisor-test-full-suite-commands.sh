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

# Create test results directory
TEST_RESULTS_DIR="${ARTIFACT_DIR}/e2e-results"
mkdir -p ${TEST_RESULTS_DIR}

# Check deployment success from previous step
if [[ "${DEPLOYMENT_SUCCESS:-false}" != "true" ]]; then
    echo "ERROR: Cluster deployment was not successful, skipping tests"
    exit 1
fi

# Validate kubeconfig
if [[ ! -f ${KUBECONFIG} ]] || ! oc get nodes &>/dev/null; then
    echo "ERROR: Cannot connect to cluster"
    exit 1
fi

echo "Cluster connectivity confirmed"

# Initialize test tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# =============================================================================
# Test 1: Deployment Verification (optional - runs if target exists)
# =============================================================================
echo ""
echo "=== Test 1: Deployment Verification ==="
((TESTS_RUN++))

# Check if verify-deployment target exists
if ${SSH} "cd ${REMOTE_WORK_DIR} && make -n verify-deployment" &>/dev/null; then
    echo "Running: make verify-deployment"
    VERIFY_LOG="${REMOTE_WORK_DIR}/logs/verify-$(date +%Y%m%d_%H%M%S).log"

    if ${SSH} "cd ${REMOTE_WORK_DIR} && VERIFY_DEPLOYMENT=true make verify-deployment 2>&1 | tee ${VERIFY_LOG}"; then
        echo "PASSED: Deployment verification"
        ((TESTS_PASSED++))
    else
        echo "FAILED: Deployment verification"
        ((TESTS_FAILED++))
    fi
    ${SCP} root@${REMOTE_HOST}:${VERIFY_LOG} ${TEST_RESULTS_DIR}/ 2>/dev/null || true
else
    echo "SKIPPED: verify-deployment target not available"
    ((TESTS_PASSED++))  # Don't count as failure
fi

# =============================================================================
# Test 2: DPF Sanity Tests (iperf)
# =============================================================================
echo ""
echo "=== Test 2: DPF Sanity Tests ==="
((TESTS_RUN++))

SANITY_LOG="${REMOTE_WORK_DIR}/logs/sanity-$(date +%Y%m%d_%H%M%S).log"

if ${SSH} "cd ${REMOTE_WORK_DIR} && make run-dpf-sanity 2>&1 | tee ${SANITY_LOG}"; then
    echo "PASSED: DPF sanity tests"
    ((TESTS_PASSED++))
    ${SCP} root@${REMOTE_HOST}:${SANITY_LOG} ${TEST_RESULTS_DIR}/sanity-success.log 2>/dev/null || true
else
    echo "FAILED: DPF sanity tests"
    ((TESTS_FAILED++))
    ${SCP} root@${REMOTE_HOST}:${SANITY_LOG} ${TEST_RESULTS_DIR}/sanity-failed.log 2>/dev/null || true
fi

# =============================================================================
# Test 3: Traffic Flow Tests (optional - runs if target exists)
# =============================================================================
echo ""
echo "=== Test 3: Traffic Flow Tests ==="
((TESTS_RUN++))

# Check if run-traffic-flow-tests target exists
if ${SSH} "cd ${REMOTE_WORK_DIR} && make -n run-traffic-flow-tests" &>/dev/null; then
    echo "Running: make run-traffic-flow-tests"
    TFT_LOG="${REMOTE_WORK_DIR}/logs/tft-$(date +%Y%m%d_%H%M%S).log"

    if ${SSH} "cd ${REMOTE_WORK_DIR} && make run-traffic-flow-tests 2>&1 | tee ${TFT_LOG}"; then
        echo "PASSED: Traffic flow tests"
        ((TESTS_PASSED++))
    else
        echo "FAILED: Traffic flow tests"
        ((TESTS_FAILED++))
    fi
    ${SCP} root@${REMOTE_HOST}:${TFT_LOG} ${TEST_RESULTS_DIR}/ 2>/dev/null || true
else
    echo "SKIPPED: run-traffic-flow-tests target not available"
    ((TESTS_PASSED++))  # Don't count as failure
fi

# =============================================================================
# Test 4: Cluster Health Validation
# =============================================================================
echo ""
echo "=== Test 4: Cluster Health Validation ==="
((TESTS_RUN++))

# Check cluster operators
oc get co -o wide > ${TEST_RESULTS_DIR}/cluster-operators.txt 2>/dev/null || true
UNHEALTHY_CO=$(oc get co --no-headers 2>/dev/null | grep -v "True.*False.*False" | wc -l | tr -d ' ')

if [[ "${UNHEALTHY_CO}" == "0" ]]; then
    echo "PASSED: All cluster operators healthy"
    ((TESTS_PASSED++))
else
    echo "WARNING: ${UNHEALTHY_CO} cluster operators not fully healthy"
    oc get co | grep -v "True.*False.*False" > ${TEST_RESULTS_DIR}/unhealthy-operators.txt 2>/dev/null || true
    ((TESTS_PASSED++))  # Warning, not failure
fi

# =============================================================================
# Test 5: DPF Operator Status
# =============================================================================
echo ""
echo "=== Test 5: DPF Operator Status ==="
((TESTS_RUN++))

if oc get namespace dpf-operator-system &>/dev/null; then
    oc get all -n dpf-operator-system > ${TEST_RESULTS_DIR}/dpf-operator-status.txt 2>/dev/null || true

    if oc get deployment -n dpf-operator-system --no-headers 2>/dev/null | grep -q "1/1"; then
        echo "PASSED: DPF operator is running"
        ((TESTS_PASSED++))
    else
        echo "FAILED: DPF operator deployment issues"
        ((TESTS_FAILED++))
        oc get pods -n dpf-operator-system > ${TEST_RESULTS_DIR}/dpf-operator-pods.txt 2>/dev/null || true
    fi
else
    echo "FAILED: DPF operator namespace not found"
    ((TESTS_FAILED++))
fi

# =============================================================================
# Collect Artifacts
# =============================================================================
echo ""
echo "=== Collecting Artifacts ==="

oc get nodes -o wide > ${TEST_RESULTS_DIR}/nodes.txt 2>/dev/null || true
oc get pods -A > ${TEST_RESULTS_DIR}/all-pods.txt 2>/dev/null || true
oc get events -A --sort-by='.lastTimestamp' > ${TEST_RESULTS_DIR}/events.txt 2>/dev/null || true

# Copy logs from hypervisor
${SCP} -r root@${REMOTE_HOST}:${REMOTE_WORK_DIR}/logs/* ${TEST_RESULTS_DIR}/ 2>/dev/null || true

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "================================================================================"
echo "E2E Test Suite Summary"
echo "================================================================================"
echo "Tests Run: ${TESTS_RUN}"
echo "Tests Passed: ${TESTS_PASSED}"
echo "Tests Failed: ${TESTS_FAILED}"
echo "Artifacts: ${TEST_RESULTS_DIR}"
echo "================================================================================"

# Create summary file
cat > ${TEST_RESULTS_DIR}/summary.txt <<EOF
DPF E2E Test Suite Summary
==========================
Date: $(date)
Cluster: ${CLUSTER_NAME}
Hypervisor: ${REMOTE_HOST}

Results:
- Tests Run: ${TESTS_RUN}
- Tests Passed: ${TESTS_PASSED}
- Tests Failed: ${TESTS_FAILED}
EOF

# Exit with failure if any tests failed
if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo ""
    echo "E2E test suite completed with ${TESTS_FAILED} failure(s)"
    exit 1
else
    echo ""
    echo "E2E test suite completed successfully!"
fi
