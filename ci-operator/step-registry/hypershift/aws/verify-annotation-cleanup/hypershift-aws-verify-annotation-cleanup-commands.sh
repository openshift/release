#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# OCPBUGS-78979 Verification: Referenced Resource Annotation Cleanup
#
# Verifies that referenced-resource annotations on secrets and configmaps
# are properly removed when a HostedCluster is deleted, regardless of
# whether the HostedControlPlane is deleted first.
# =============================================================================

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "[SKIP] $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

ANNOTATION_PREFIX="referenced-resource.hypershift.openshift.io/"
HC_NAMESPACE="clusters"

# KUBECONFIG is inherited from the CI framework (set by the nested management
# cluster setup chain via SHARED_DIR/kubeconfig). Do NOT override it.
echo "Using KUBECONFIG: ${KUBECONFIG}"

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

# --- Step 1: Create HostedCluster ---
echo ""
echo "=== Step 1: Create HostedCluster ==="

AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ ! -f "${AWS_GUEST_INFRA_CREDENTIALS_FILE}" ]]; then
  echo "AWS credentials file not found at ${AWS_GUEST_INFRA_CREDENTIALS_FILE}"
  exit 1
fi

RELEASE_IMAGE="${RELEASE_IMAGE_LATEST}"
if [[ -z "${RELEASE_IMAGE}" ]]; then
  echo "RELEASE_IMAGE_LATEST is not set"
  exit 1
fi

DOMAIN="${HYPERSHIFT_BASE_DOMAIN}"
if [[ -z "${DOMAIN}" ]]; then
  if [[ -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
    DOMAIN=$(< "${CLUSTER_PROFILE_DIR}/baseDomain")
  fi
fi
DOMAIN="${DOMAIN:-ci.hypershift.devcluster.openshift.com}"

HASH="$(echo -n "${PROW_JOB_ID}"|sha256sum)"
CLUSTER_NAME="${HASH:0:20}"
INFRA_ID="${HASH:20:5}"
echo "Using cluster name: ${CLUSTER_NAME}, infra ID: ${INFRA_ID}"

# Save cluster info for cleanup
echo "CLUSTER_NAME=${CLUSTER_NAME}" > "${SHARED_DIR}/hosted_cluster.txt"
echo "INFRA_ID=${INFRA_ID}" >> "${SHARED_DIR}/hosted_cluster.txt"

# Generate pull secret
oc registry login --to="${SHARED_DIR}/pull-secret-build-farm.json"
if [[ -f "${SHARED_DIR}/pull-secret-build-farm.json" ]]; then
  jq -s '.[0] * .[1]' "${SHARED_DIR}/pull-secret-build-farm.json" /etc/ci-pull-credentials/.dockerconfigjson > /tmp/pull-secret.json
else
  cp /etc/ci-pull-credentials/.dockerconfigjson /tmp/pull-secret.json
fi

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)

echo "Creating HostedCluster ${CLUSTER_NAME}..."
bin/hypershift create cluster aws \
  --name "${CLUSTER_NAME}" \
  --infra-id "${INFRA_ID}" \
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
  --instance-type "m5.xlarge" \
  --base-domain "${DOMAIN}" \
  --region "${HYPERSHIFT_AWS_REGION}" \
  --pull-secret /tmp/pull-secret.json \
  --aws-creds "${AWS_GUEST_INFRA_CREDENTIALS_FILE}" \
  --release-image "${RELEASE_IMAGE}" \
  --annotations "prow.k8s.io/job=${JOB_NAME}" \
  --annotations "prow.k8s.io/build-id=${BUILD_ID}" \
  --annotations "hypershift.openshift.io/cleanup-cloud-resources=false" \
  --additional-tags "expirationDate=${EXPIRATION_DATE}" \
  --additional-tags "prow.k8s.io/job=${JOB_NAME}" \
  --additional-tags "prow.k8s.io/build-id=${BUILD_ID}"

echo "Waiting for HostedCluster to become available..."
oc wait --timeout=30m --for=condition=Available --namespace="${HC_NAMESPACE}" "hostedcluster/${CLUSTER_NAME}" || {
  echo "Cluster did not become available"
  mkdir -p "${ARTIFACT_DIR}/hypershift-snapshot"
  oc get hostedcluster "${CLUSTER_NAME}" --namespace="${HC_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/hypershift-snapshot/hostedcluster_failed.yaml" || true
  fail "HostedCluster did not become available within 30m"
  echo "RESULT: SETUP FAILED"
  exit 1
}
pass "HostedCluster ${CLUSTER_NAME} is available"

# --- Step 2: Verify annotations are SET on referenced resources ---
echo ""
echo "=== Step 2: Verify annotations are set on referenced resources ==="

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

# --- Step 3: Delete HostedCluster ---
echo ""
echo "=== Step 3: Delete HostedCluster ==="

echo "Deleting HostedCluster ${CLUSTER_NAME}..."
bin/hypershift destroy cluster aws \
  --aws-creds="${AWS_GUEST_INFRA_CREDENTIALS_FILE}" \
  --name "${CLUSTER_NAME}" \
  --infra-id "${INFRA_ID}" \
  --region "${HYPERSHIFT_AWS_REGION}" \
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

# --- Step 4: Verify annotations are REMOVED (core verification) ---
echo ""
echo "=== Step 4: Verify annotations are removed (CORE CHECK) ==="

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

# --- Step 5: Verify no stale annotations from ANY deleted HC ---
echo ""
echo "=== Step 5: Verify no orphaned referenced-resource annotations ==="

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
