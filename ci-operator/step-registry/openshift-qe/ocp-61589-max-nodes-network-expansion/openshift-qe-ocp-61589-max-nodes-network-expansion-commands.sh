#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OCP-61589: Maximum nodes post cluster network expansion test
# This test validates that after expanding cluster network CIDR from /20 to /14,
# approximately 512 nodes can become Ready before hitting subnet exhaustion.

EXPECTED_READY_NODES=${EXPECTED_READY_NODES:-512}
TOTAL_SCALE_NODES=${TOTAL_SCALE_NODES:-520}
EXPANSION_TARGET_CIDR=${EXPANSION_TARGET_CIDR:-10.128.0.0/14}

echo "=========================================="
echo "OCP-61589: Maximum nodes network expansion test"
echo "Expected ready nodes: ${EXPECTED_READY_NODES}"
echo "Total scale target: ${TOTAL_SCALE_NODES}"
echo "Expansion target CIDR: ${EXPANSION_TARGET_CIDR}"
echo "=========================================="

# Wait for cluster to be ready
echo "Waiting for cluster operators to be ready..."
oc wait --for=condition=Available --timeout=30m clusteroperator --all

# Get initial cluster state
echo "Capturing initial cluster state..."
INITIAL_NODES=$(oc get nodes --no-headers | wc -l)
echo "Initial node count: ${INITIAL_NODES}"

# Get initial network configuration
echo "Initial network configuration:"
oc get network.config cluster -o yaml

# Perform network expansion (this should already be done by ovn-clusternetwork-cidr-expansion step)
echo "Checking if network expansion has occurred..."
CURRENT_CIDR=$(oc get network.config cluster -o jsonpath='{.spec.clusterNetwork[0].cidr}')
echo "Current CIDR: ${CURRENT_CIDR}"

if [[ "${CURRENT_CIDR}" == "${EXPANSION_TARGET_CIDR}" ]]; then
  echo "✅ Network expansion already completed to ${EXPANSION_TARGET_CIDR}"
else
  echo "❌ Network expansion not detected. Expected ${EXPANSION_TARGET_CIDR}, got ${CURRENT_CIDR}"
  exit 1
fi

# Scale machinesets to test subnet exhaustion
echo "Scaling machinesets to ${TOTAL_SCALE_NODES} total nodes..."

# Get all worker machinesets
MACHINESETS=$(oc get machineset -n openshift-machine-api -o name | grep worker)
MACHINESET_COUNT=$(echo "${MACHINESETS}" | wc -l)

if [[ ${MACHINESET_COUNT} -eq 0 ]]; then
  echo "❌ No worker machinesets found"
  exit 1
fi

echo "Found ${MACHINESET_COUNT} worker machinesets"

# Calculate target replicas per machineset (accounting for initial nodes)
TARGET_WORKER_NODES=$((TOTAL_SCALE_NODES - INITIAL_NODES))
REPLICAS_PER_MACHINESET=$((TARGET_WORKER_NODES / MACHINESET_COUNT))

echo "Scaling each machineset to ${REPLICAS_PER_MACHINESET} replicas..."

# Scale all machinesets
for machineset in ${MACHINESETS}; do
  echo "Scaling ${machineset} to ${REPLICAS_PER_MACHINESET} replicas..."
  oc scale -n openshift-machine-api "${machineset}" --replicas="${REPLICAS_PER_MACHINESET}"
done

# Wait for nodes to be provisioned and monitor readiness
echo "Monitoring node scaling progress..."
TIMEOUT_MINUTES=60
INTERVAL_SECONDS=30
ELAPSED=0

while [[ ${ELAPSED} -lt $((TIMEOUT_MINUTES * 60)) ]]; do
  CURRENT_NODES=$(oc get nodes --no-headers | wc -l)
  READY_NODES=$(oc get nodes --no-headers | grep " Ready " | wc -l)
  NOTREADY_NODES=$(oc get nodes --no-headers | grep " NotReady " | wc -l)
  
  echo "Time: ${ELAPSED}s | Total: ${CURRENT_NODES} | Ready: ${READY_NODES} | NotReady: ${NOTREADY_NODES}"
  
  # Check if we've hit the expected pattern
  if [[ ${READY_NODES} -ge ${EXPECTED_READY_NODES} && ${NOTREADY_NODES} -gt 0 ]]; then
    echo "✅ SUCCESS: Subnet exhaustion pattern detected!"
    echo "Ready nodes: ${READY_NODES} (>= ${EXPECTED_READY_NODES})"
    echo "NotReady nodes: ${NOTREADY_NODES} (> 0)"
    break
  fi
  
  sleep ${INTERVAL_SECONDS}
  ELAPSED=$((ELAPSED + INTERVAL_SECONDS))
done

# Final validation
FINAL_NODES=$(oc get nodes --no-headers | wc -l)
FINAL_READY=$(oc get nodes --no-headers | grep " Ready " | wc -l)
FINAL_NOTREADY=$(oc get nodes --no-headers | grep " NotReady " | wc -l)

echo "=========================================="
echo "FINAL RESULTS:"
echo "Total nodes: ${FINAL_NODES}"
echo "Ready nodes: ${FINAL_READY}"
echo "NotReady nodes: ${FINAL_NOTREADY}"
echo "=========================================="

# Create results summary
RESULTS_DIR="${SHARED_DIR}/ocp-61589-results"
mkdir -p "${RESULTS_DIR}"

# Save detailed results
oc get nodes -o wide > "${RESULTS_DIR}/final-nodes.txt"
oc get machineset -n openshift-machine-api > "${RESULTS_DIR}/final-machinesets.txt"
oc get network.config cluster -o yaml > "${RESULTS_DIR}/final-network-config.yaml"

# Create summary
cat > "${RESULTS_DIR}/test-summary.txt" << EOF
OCP-61589 Test Results Summary
==============================
Test Objective: Validate ~512 nodes become Ready after network expansion, rest NotReady
Network Expansion: /20 → /14
Expected Ready Nodes: ${EXPECTED_READY_NODES}
Total Scale Target: ${TOTAL_SCALE_NODES}

Results:
--------
Total Nodes: ${FINAL_NODES}
Ready Nodes: ${FINAL_READY}
NotReady Nodes: ${FINAL_NOTREADY}

Test Status: $([[ ${FINAL_READY} -ge ${EXPECTED_READY_NODES} && ${FINAL_NOTREADY} -gt 0 ]] && echo "PASS" || echo "FAIL")
EOF

# Validate test success
if [[ ${FINAL_READY} -ge ${EXPECTED_READY_NODES} && ${FINAL_NOTREADY} -gt 0 ]]; then
  echo "✅ OCP-61589 TEST PASSED"
  echo "   Ready nodes (${FINAL_READY}) >= expected (${EXPECTED_READY_NODES})"
  echo "   NotReady nodes (${FINAL_NOTREADY}) > 0 (subnet exhaustion confirmed)"
  exit 0
else
  echo "❌ OCP-61589 TEST FAILED"
  if [[ ${FINAL_READY} -lt ${EXPECTED_READY_NODES} ]]; then
    echo "   Ready nodes (${FINAL_READY}) < expected (${EXPECTED_READY_NODES})"
  fi
  if [[ ${FINAL_NOTREADY} -eq 0 ]]; then
    echo "   No NotReady nodes found - subnet exhaustion not detected"
  fi
  exit 1
fi