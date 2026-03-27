#!/bin/bash

set -euo pipefail

# Verify CVO manifest feature-set annotation filtering (OCPBUGS-78705)
# This step execs into the CVO pod on the management cluster and verifies
# that manifests in /var/payload/manifests/ were correctly filtered based
# on the release.openshift.io/feature-set annotation.

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "[PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "[SKIP] $*"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
HC_NAMESPACE="clusters"
CP_NAMESPACE="${HC_NAMESPACE}-${CLUSTER_NAME}"

echo "=== CVO Manifest Feature-Set Annotation Filtering Verification ==="
echo "Cluster: ${CLUSTER_NAME}"
echo "Control Plane Namespace: ${CP_NAMESPACE}"
echo "Expected Feature Set: ${EXPECTED_FEATURE_SET}"
echo ""

# --- Step 1: Find the CVO pod ---
echo "--- Step 1: Locate CVO pod ---"
CVO_POD=$(oc get pods -n "${CP_NAMESPACE}" -l app=cluster-version-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${CVO_POD}" ]]; then
    fail "CVO pod not found in namespace ${CP_NAMESPACE}"
    echo "Available pods:"
    oc get pods -n "${CP_NAMESPACE}" --no-headers 2>/dev/null || true
    echo ""
    echo "=== SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped ==="
    exit 1
fi
pass "CVO pod found: ${CVO_POD}"

# Verify CVO pod is Running
CVO_STATUS=$(oc get pod "${CVO_POD}" -n "${CP_NAMESPACE}" -o jsonpath='{.status.phase}')
if [[ "${CVO_STATUS}" == "Running" ]]; then
    pass "CVO pod is Running (init container completed successfully)"
else
    fail "CVO pod status is ${CVO_STATUS}, expected Running"
    echo ""
    echo "=== SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped ==="
    exit 1
fi

# --- Step 2: List manifests in /var/payload/manifests/ ---
echo ""
echo "--- Step 2: Inventory payload manifests ---"
MANIFEST_COUNT=$(oc exec -n "${CP_NAMESPACE}" "${CVO_POD}" -c cluster-version-operator -- find /var/payload/manifests/ -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${MANIFEST_COUNT}" -gt 0 ]]; then
    pass "Found ${MANIFEST_COUNT} manifests in /var/payload/manifests/"
else
    fail "No manifests found in /var/payload/manifests/"
    echo ""
    echo "=== SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped ==="
    exit 1
fi

# --- Step 3: Verify feature-set annotation filtering ---
echo ""
echo "--- Step 3: Verify feature-set annotation filtering ---"

# Get all manifests and check their annotations
# For each file with a feature-set annotation, verify it matches the expected feature set
WRONG_MANIFESTS=""
ANNOTATED_COUNT=0
UNANNOTATED_COUNT=0
MATCHING_COUNT=0

while IFS= read -r file; do
    # Extract feature-set annotation value from the file
    ANNOTATION=$(oc exec -n "${CP_NAMESPACE}" "${CVO_POD}" -c cluster-version-operator -- \
        grep "release.openshift.io/feature-set:" "${file}" 2>/dev/null | awk '{print $2}' | head -1 || true)

    if [[ -n "${ANNOTATION}" ]]; then
        ANNOTATED_COUNT=$((ANNOTATED_COUNT + 1))
        # Check if the expected feature set is in the annotation (comma-separated)
        if echo " ${ANNOTATION} " | grep -q "${EXPECTED_FEATURE_SET}"; then
            MATCHING_COUNT=$((MATCHING_COUNT + 1))
        else
            WRONG_MANIFESTS="${WRONG_MANIFESTS}  ${file} (annotation: ${ANNOTATION})\n"
        fi
    else
        UNANNOTATED_COUNT=$((UNANNOTATED_COUNT + 1))
    fi
done < <(oc exec -n "${CP_NAMESPACE}" "${CVO_POD}" -c cluster-version-operator -- find /var/payload/manifests/ -name "*.yaml" 2>/dev/null)

echo "  Manifests with feature-set annotation: ${ANNOTATED_COUNT}"
echo "  Manifests matching ${EXPECTED_FEATURE_SET}: ${MATCHING_COUNT}"
echo "  Manifests without annotation (unconditionally included): ${UNANNOTATED_COUNT}"

if [[ -z "${WRONG_MANIFESTS}" ]]; then
    pass "No manifests with non-matching feature-set annotations found"
else
    fail "Found manifests with wrong feature-set annotation:"
    echo -e "${WRONG_MANIFESTS}"
fi

if [[ "${UNANNOTATED_COUNT}" -gt 0 ]]; then
    pass "Unannotated manifests are correctly included (${UNANNOTATED_COUNT} files)"
else
    skip "No unannotated manifests found (all have feature-set annotation)"
fi

if [[ "${ANNOTATED_COUNT}" -gt 0 ]] && [[ "${MATCHING_COUNT}" -gt 0 ]]; then
    pass "Manifests with matching feature-set annotation are present (${MATCHING_COUNT} files)"
elif [[ "${ANNOTATED_COUNT}" -eq 0 ]]; then
    skip "No manifests with feature-set annotation found to verify matching"
else
    fail "No manifests with matching feature-set '${EXPECTED_FEATURE_SET}' found (${ANNOTATED_COUNT} annotated manifests checked)"
fi

# --- Step 4: Verify CVO health ---
echo ""
echo "--- Step 4: Verify CVO health ---"

# Check ClusterVersion on the hosted cluster
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

CV_AVAILABLE=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
CV_DEGRADED=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
CV_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "Unknown")

echo "  ClusterVersion: ${CV_VERSION}"
echo "  Available: ${CV_AVAILABLE}"
echo "  Degraded: ${CV_DEGRADED}"

if [[ "${CV_AVAILABLE}" == "True" ]]; then
    pass "ClusterVersion is Available"
else
    fail "ClusterVersion Available=${CV_AVAILABLE} (expected True)"
fi

if [[ "${CV_DEGRADED}" != "True" ]]; then
    pass "ClusterVersion is not Degraded"
else
    CV_DEGRADED_MSG=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null || echo "unknown")
    fail "ClusterVersion is Degraded: ${CV_DEGRADED_MSG}"
fi

# --- Summary ---
echo ""
echo "=== SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped ==="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    echo "RESULT: CHECKS FAILED"
    exit 1
else
    echo "RESULT: ALL CHECKS PASSED"
fi
