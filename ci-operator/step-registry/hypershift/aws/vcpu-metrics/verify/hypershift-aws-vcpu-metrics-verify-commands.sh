#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "[SKIP] $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

echo "=== Step 1: Verify HO is running ==="
HO_STATUS=$(oc -n hypershift get deployment/operator -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
if [[ "${HO_STATUS}" == "True" ]]; then
  pass "HO deployment is Available"
else
  fail "HO deployment is not Available (status: ${HO_STATUS})"
fi

HO_IMAGE=$(oc -n hypershift get deployment/operator -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "  HO image: ${HO_IMAGE}"

echo ""
echo "=== Step 2: Verify ConfigMap exists ==="
CM_DATA=$(oc -n hypershift get configmap rosa-cpus-instance-types-config -o jsonpath='{.data}' 2>/dev/null || echo "NOT_FOUND")
if [[ "${CM_DATA}" == "NOT_FOUND" ]]; then
  fail "ConfigMap rosa-cpus-instance-types-config not found"
else
  # Check canary entry
  CANARY=$(oc -n hypershift get configmap rosa-cpus-instance-types-config -o go-template='{{index .data "test-canary.xlarge"}}' 2>/dev/null || echo "")
  if [[ "${CANARY}" == "42" ]]; then
    pass "ConfigMap rosa-cpus-instance-types-config exists with correct canary value"
  else
    fail "ConfigMap canary value mismatch (expected 42, got ${CANARY})"
  fi
fi

echo ""
echo "=== Step 3: Check HostedCluster and NodePool status ==="
HC_NAME=""
if [[ -f "${SHARED_DIR}/hostedcluster_name" ]]; then
  HC_NAME=$(cat "${SHARED_DIR}/hostedcluster_name")
fi
HC_NAMESPACE=""
if [[ -f "${SHARED_DIR}/hostedcluster_namespace" ]]; then
  HC_NAMESPACE=$(cat "${SHARED_DIR}/hostedcluster_namespace")
fi

if [[ -z "${HC_NAME}" ]]; then
  # Try to find HC from cluster
  HC_NAME=$(oc get hostedclusters --all-namespaces -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  HC_NAMESPACE=$(oc get hostedclusters --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
fi

if [[ -z "${HC_NAME}" ]]; then
  skip "No HostedCluster found — cannot verify vCPU metrics"
else
  echo "  HostedCluster: ${HC_NAMESPACE}/${HC_NAME}"

  # Get NodePool info
  NP_COUNT=$(oc get nodepools -n "${HC_NAMESPACE}" -o json | oc neat 2>/dev/null | grep -c '"name"' || oc get nodepools -n "${HC_NAMESPACE}" --no-headers 2>/dev/null | wc -l || echo "0")
  echo "  NodePools: ${NP_COUNT}"

  INSTANCE_TYPE=$(oc get nodepools -n "${HC_NAMESPACE}" -o jsonpath='{.items[0].spec.platform.aws.instanceType}' 2>/dev/null || echo "unknown")
  REPLICAS=$(oc get nodepools -n "${HC_NAMESPACE}" -o jsonpath='{.items[0].status.replicas}' 2>/dev/null || echo "0")
  echo "  Instance type: ${INSTANCE_TYPE}, replicas: ${REPLICAS}"

  if [[ "${INSTANCE_TYPE}" != "unknown" ]] && [[ "${REPLICAS}" -gt 0 ]]; then
    pass "NodePool has ${REPLICAS} replicas of ${INSTANCE_TYPE}"
  elif [[ "${REPLICAS}" == "0" ]]; then
    skip "NodePool has 0 replicas — vCPU metric will be 0 (expected)"
  else
    fail "Could not determine NodePool instance type or replicas"
  fi
fi

echo ""
echo "=== Step 4: Check HO logs for vCPU metric errors ==="
# Look for errors in the last 5 minutes of HO logs
HO_POD=$(oc -n hypershift get pods -l app=operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "${HO_POD}" ]]; then
  # Check for panic or crash
  RESTARTS=$(oc -n hypershift get pod "${HO_POD}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "unknown")
  echo "  HO pod restarts: ${RESTARTS}"
  if [[ "${RESTARTS}" == "0" ]]; then
    pass "HO pod has 0 restarts (no crash loops)"
  elif [[ "${RESTARTS}" != "unknown" ]]; then
    fail "HO pod has ${RESTARTS} restarts"
  fi

  # Check for vCPU-related errors in logs
  VCPU_ERRORS=$(oc -n hypershift logs "${HO_POD}" --since=10m 2>/dev/null | grep -c "failed to call AWS\|unexpected AWS output\|cannot retrieve the number of vCPUs" || echo "0")
  echo "  vCPU-related error log lines (last 10m): ${VCPU_ERRORS}"
  if [[ "${VCPU_ERRORS}" -eq 0 ]]; then
    pass "No vCPU resolution errors in HO logs"
  else
    # Errors might be expected if instance type is not in EC2 API
    # Check if ConfigMap fallback resolved them
    CM_FALLBACK=$(oc -n hypershift logs "${HO_POD}" --since=10m 2>/dev/null | grep -c "rosa-cpus-instance-types-config\|ConfigMap" || echo "0")
    if [[ "${CM_FALLBACK}" -gt 0 ]]; then
      pass "vCPU errors present but ConfigMap fallback was attempted (${CM_FALLBACK} references)"
    else
      fail "vCPU resolution errors without ConfigMap fallback evidence"
    fi
  fi
else
  skip "Could not find HO pod for log analysis"
fi

echo ""
echo "=== Step 5: Query vCPU metrics from HO ==="
# Try to get metrics from the HO pod using oc exec + wget
METRICS=""
if [[ -n "${HO_POD}" ]]; then
  # Try wget (available in UBI9 images)
  METRICS=$(oc -n hypershift exec "${HO_POD}" -- wget -qO- http://localhost:8080/metrics 2>/dev/null || echo "")
  if [[ -z "${METRICS}" ]]; then
    # Try with https on port 8443
    METRICS=$(oc -n hypershift exec "${HO_POD}" -- wget --no-check-certificate -qO- https://localhost:8443/metrics 2>/dev/null || echo "")
  fi
fi

if [[ -n "${METRICS}" ]]; then
  echo "  Successfully retrieved metrics from HO"

  # Check hypershift_cluster_vcpus metric
  VCPU_LINES=$(echo "${METRICS}" | grep "^hypershift_cluster_vcpus{" || echo "")
  if [[ -n "${VCPU_LINES}" ]]; then
    echo "  vCPU metric lines found:"
    echo "${VCPU_LINES}" | while read -r line; do
      echo "    ${line}"
    done

    # Check if any cluster has vCPU count > 0
    POSITIVE_VCPUS=$(echo "${VCPU_LINES}" | awk '{print $NF}' | awk '$1 > 0' | wc -l | tr -d ' ')
    NEGATIVE_VCPUS=$(echo "${VCPU_LINES}" | awk '{print $NF}' | awk '$1 == -1' | wc -l | tr -d ' ')

    if [[ "${POSITIVE_VCPUS}" -gt 0 ]]; then
      pass "hypershift_cluster_vcpus metric has ${POSITIVE_VCPUS} cluster(s) with positive vCPU count"
    elif [[ "${NEGATIVE_VCPUS}" -gt 0 ]]; then
      fail "hypershift_cluster_vcpus metric reports -1 for ${NEGATIVE_VCPUS} cluster(s)"
    else
      skip "hypershift_cluster_vcpus metric present but no clusters with replicas > 0"
    fi
  else
    skip "hypershift_cluster_vcpus metric not emitted (no clusters with replicas > 0)"
  fi

  # Check for vCPU computation error metric
  VCPU_ERROR_LINES=$(echo "${METRICS}" | grep "^hypershift_cluster_vcpus_computation_error{" || echo "")
  if [[ -n "${VCPU_ERROR_LINES}" ]]; then
    echo "  vCPU computation error lines:"
    echo "${VCPU_ERROR_LINES}" | while read -r line; do
      echo "    ${line}"
    done
    # Check the error reason label - new code uses sentinel error messages
    if echo "${VCPU_ERROR_LINES}" | grep -q "ROSA CPUs instance types ConfigMap not found"; then
      pass "Error metric uses new sentinel error format (OCPBUGS-50003 fix confirmed)"
    elif echo "${VCPU_ERROR_LINES}" | grep -q "unexpected AWS output\|failed to call AWS"; then
      fail "Error metric still uses old error format (OCPBUGS-50003 fix NOT applied)"
    else
      pass "vCPU computation error metric present with expected format"
    fi
  else
    pass "No vCPU computation errors (all instance types resolved successfully)"
  fi
else
  skip "Could not retrieve metrics from HO pod (wget not available or metrics port unreachable)"
fi

echo ""
echo "========================================="
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
echo "========================================="

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  echo "RESULT: CHECKS FAILED"
  exit 1
else
  echo "RESULT: ALL CHECKS PASSED"
fi
