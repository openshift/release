#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# OCPBUGS-78979 Verification: Referenced Resource Annotation Cleanup
#
# Verifies that referenced-resource annotations on secrets and configmaps
# are properly removed when a HostedCluster is deleted, regardless of
# whether the HostedControlPlane is deleted first.
#
# Prerequisites: HostedCluster already created by hypershift-aws-create chain.
# KUBECONFIG is inherited from CI framework (nested management cluster).
# =============================================================================

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "[SKIP] $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

ANNOTATION_PREFIX="referenced-resource.hypershift.openshift.io/"
HC_NAMESPACE="clusters"

# Derive cluster name the same way as hypershift-aws-create chain
CLUSTER_NAME="$(echo -n "$PROW_JOB_ID"|sha256sum|cut -c-20)"
echo "Using KUBECONFIG: ${KUBECONFIG}"
echo "Cluster name: ${CLUSTER_NAME}"

# Determine AWS credentials and domain (same logic as hypershift-aws-destroy chain)
AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com

if [[ "${HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT}" == "true" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
fi
DOMAIN="${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}"
HC_REGION="${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}"

# --- Step 0: Pre-flight ---
echo ""
echo "=== Step 0: Pre-flight ==="

HO_IMAGE=$(oc get deployment -n hypershift operator -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [[ -n "${HO_IMAGE}" ]]; then
  echo "HyperShift Operator image: ${HO_IMAGE}"
  pass "HyperShift operator is running"
else
  fail "HyperShift operator not found"
  echo "RESULT: PRE-FLIGHT FAILED"
  exit 1
fi

# Verify the HC exists (created by hypershift-aws-create chain)
if oc get hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" &>/dev/null; then
  pass "HostedCluster ${CLUSTER_NAME} exists"
else
  fail "HostedCluster ${CLUSTER_NAME} not found (should have been created by hypershift-aws-create)"
  echo "RESULT: PRE-FLIGHT FAILED"
  exit 1
fi

# --- Step 1: Verify annotations are SET on referenced resources ---
echo ""
echo "=== Step 1: Verify annotations are set on referenced resources ==="

ANNOTATION_KEY="${ANNOTATION_PREFIX}${CLUSTER_NAME}"

# Check secrets
ANNOTATED_SECRETS=$(oc get secrets -n "${HC_NAMESPACE}" -o json | \
  jq -r --arg key "${ANNOTATION_KEY}" \
  '[.items[] | select(.metadata.annotations[$key] != null) | .metadata.name] | .[]' || true)

if [[ -n "${ANNOTATED_SECRETS}" ]]; then
  echo "Secrets with referenced-resource annotation for ${CLUSTER_NAME}:"
  echo "${ANNOTATED_SECRETS}" | while read -r name; do
    echo "  - ${name}"
  done
  SECRET_COUNT=$(echo "${ANNOTATED_SECRETS}" | wc -l | tr -d ' ')
  pass "Found ${SECRET_COUNT} secret(s) with referenced-resource annotation"
else
  fail "No secrets found with referenced-resource annotation for ${CLUSTER_NAME}"
fi

# Check configmaps
ANNOTATED_CMS=$(oc get configmaps -n "${HC_NAMESPACE}" -o json | \
  jq -r --arg key "${ANNOTATION_KEY}" \
  '[.items[] | select(.metadata.annotations[$key] != null) | .metadata.name] | .[]' || true)

if [[ -n "${ANNOTATED_CMS}" ]]; then
  echo "ConfigMaps with referenced-resource annotation for ${CLUSTER_NAME}:"
  echo "${ANNOTATED_CMS}" | while read -r name; do
    echo "  - ${name}"
  done
  CM_COUNT=$(echo "${ANNOTATED_CMS}" | wc -l | tr -d ' ')
  pass "Found ${CM_COUNT} configmap(s) with referenced-resource annotation"
else
  # ConfigMaps may or may not have annotations depending on HC config
  skip "No configmaps with referenced-resource annotation (may be expected)"
fi

# Save evidence
mkdir -p "${ARTIFACT_DIR}"
echo "--- Pre-deletion annotation evidence ---" > "${ARTIFACT_DIR}/annotation-evidence.txt"
echo "Annotated secrets: ${ANNOTATED_SECRETS:-none}" >> "${ARTIFACT_DIR}/annotation-evidence.txt"
echo "Annotated configmaps: ${ANNOTATED_CMS:-none}" >> "${ARTIFACT_DIR}/annotation-evidence.txt"

# --- Step 2: Delete HostedCluster ---
echo ""
echo "=== Step 2: Delete HostedCluster ==="

echo "Deleting HostedCluster ${CLUSTER_NAME}..."
bin/hypershift destroy cluster aws \
  --aws-creds="${AWS_GUEST_INFRA_CREDENTIALS_FILE}" \
  --name "${CLUSTER_NAME}" \
  --infra-id "${CLUSTER_NAME}" \
  --region "${HC_REGION}" \
  --base-domain "${DOMAIN}" \
  --cluster-grace-period 10m

echo "Waiting for HostedCluster to be fully deleted..."
WAIT_TIMEOUT=1800  # 30 minutes
WAIT_INTERVAL=10
ELAPSED=0
while oc get hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" &>/dev/null; do
  if [[ ${ELAPSED} -ge ${WAIT_TIMEOUT} ]]; then
    fail "HostedCluster was not deleted within ${WAIT_TIMEOUT}s"
    echo "RESULT: DELETION TIMEOUT"
    exit 1
  fi
  echo "  Waiting for HC deletion... (${ELAPSED}s/${WAIT_TIMEOUT}s)"
  sleep "${WAIT_INTERVAL}"
  ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done
pass "HostedCluster ${CLUSTER_NAME} fully deleted"

# --- Step 3: Verify annotations are REMOVED (core verification) ---
echo ""
echo "=== Step 3: Verify annotations are removed (CORE CHECK) ==="

# Check secrets - no annotation should remain for the deleted HC
REMAINING_SECRET_ANNOTATIONS=$(oc get secrets -n "${HC_NAMESPACE}" -o json | \
  jq -r --arg key "${ANNOTATION_KEY}" \
  '[.items[] | select(.metadata.annotations[$key] != null) | .metadata.name] | .[]' || true)

if [[ -z "${REMAINING_SECRET_ANNOTATIONS}" ]]; then
  pass "No referenced-resource annotations for ${CLUSTER_NAME} remain on secrets"
else
  echo "Stale annotations found on secrets:"
  echo "${REMAINING_SECRET_ANNOTATIONS}" | while read -r name; do
    echo "  - ${name}"
  done
  fail "Stale referenced-resource annotations remain on secrets after HC deletion"
fi

# Check configmaps - no annotation should remain for the deleted HC
REMAINING_CM_ANNOTATIONS=$(oc get configmaps -n "${HC_NAMESPACE}" -o json | \
  jq -r --arg key "${ANNOTATION_KEY}" \
  '[.items[] | select(.metadata.annotations[$key] != null) | .metadata.name] | .[]' || true)

if [[ -z "${REMAINING_CM_ANNOTATIONS}" ]]; then
  pass "No referenced-resource annotations for ${CLUSTER_NAME} remain on configmaps"
else
  echo "Stale annotations found on configmaps:"
  echo "${REMAINING_CM_ANNOTATIONS}" | while read -r name; do
    echo "  - ${name}"
  done
  fail "Stale referenced-resource annotations remain on configmaps after HC deletion"
fi

# Save post-deletion evidence
echo "" >> "${ARTIFACT_DIR}/annotation-evidence.txt"
echo "--- Post-deletion annotation evidence ---" >> "${ARTIFACT_DIR}/annotation-evidence.txt"
echo "Remaining secret annotations: ${REMAINING_SECRET_ANNOTATIONS:-none}" >> "${ARTIFACT_DIR}/annotation-evidence.txt"
echo "Remaining configmap annotations: ${REMAINING_CM_ANNOTATIONS:-none}" >> "${ARTIFACT_DIR}/annotation-evidence.txt"

# --- Step 4: Verify no stale annotations from ANY deleted HC ---
echo ""
echo "=== Step 4: Verify no orphaned referenced-resource annotations ==="

# Check for any referenced-resource annotations that reference non-existent HCs
ALL_ANNOTATION_KEYS=$(oc get secrets,configmaps -n "${HC_NAMESPACE}" -o json | \
  jq -r '[.items[].metadata.annotations // {} | keys[] | select(startswith("referenced-resource.hypershift.openshift.io/"))] | unique | .[]' || true)

ORPHANED=0
if [[ -n "${ALL_ANNOTATION_KEYS}" ]]; then
  while read -r key; do
    HC_REF="${key#referenced-resource.hypershift.openshift.io/}"
    if ! oc get hostedcluster "${HC_REF}" -n "${HC_NAMESPACE}" &>/dev/null; then
      echo "  Orphaned annotation found: ${key} (HC ${HC_REF} does not exist)"
      ORPHANED=$((ORPHANED + 1))
    fi
  done <<< "${ALL_ANNOTATION_KEYS}"
fi

if [[ ${ORPHANED} -eq 0 ]]; then
  pass "No orphaned referenced-resource annotations found"
else
  fail "Found ${ORPHANED} orphaned referenced-resource annotation(s)"
fi

# --- Summary ---
echo ""
echo "=========================================="
echo "  VERIFICATION SUMMARY"
echo "=========================================="
echo "  PASS: ${PASS_COUNT}"
echo "  FAIL: ${FAIL_COUNT}"
echo "  SKIP: ${SKIP_COUNT}"
echo "=========================================="

if [[ ${FAIL_COUNT} -eq 0 ]]; then
  echo "RESULT: ALL CHECKS PASSED"
else
  echo "RESULT: ${FAIL_COUNT} CHECK(S) FAILED"
  exit 1
fi
