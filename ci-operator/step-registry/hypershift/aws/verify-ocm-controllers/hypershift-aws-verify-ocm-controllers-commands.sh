#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Verify: CPO v2 preserves HCCO modifications to OCM Controllers field
# Bug: OCPBUGS-81836 / OCPBUGS-79539
#
# When Image Registry managementState is set to Removed, HCCO disables the
# pull-secrets controller in the OCM ConfigMap. CPO v2 must preserve this
# modification instead of overwriting it.
# ============================================================================

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "[SKIP] $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# --- Setup ---
echo "=== Setup: Create HostedCluster ==="

RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}
echo "Using release image: ${RELEASE_IMAGE}"

# Generate pull secret
oc registry login --to=/tmp/pull-secret-build-farm.json
jq -s '.[0] * .[1]' /tmp/pull-secret-build-farm.json /etc/ci-pull-credentials/.dockerconfigjson > /tmp/pull-secret.json

# Management cluster kubeconfig
export MGMT_KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

# Cluster naming
HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}
INFRA_ID=${HASH:20:5}
echo "Cluster name: ${CLUSTER_NAME}, Infra ID: ${INFRA_ID}"

# Base domain — default matches the shared root management cluster DNS zone
DEFAULT_BASE_DOMAIN="ci.hypershift.devcluster.openshift.com"
DOMAIN=""
if [[ -n "${HYPERSHIFT_BASE_DOMAIN:-}" ]]; then
  DOMAIN="${HYPERSHIFT_BASE_DOMAIN}"
elif [[ -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
  DOMAIN=$(< "${CLUSTER_PROFILE_DIR}/baseDomain")
else
  DOMAIN="${DEFAULT_BASE_DOMAIN}"
fi
echo "Using base domain: ${DOMAIN}"

AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)

# Build CPO override args if image is specified
CPO_ARGS=""
if [[ -n "${CPO_IMAGE:-}" ]]; then
  echo "Using CPO image override: ${CPO_IMAGE}"
  CPO_ARGS="--annotations hypershift.openshift.io/control-plane-operator-image=${CPO_IMAGE}"
fi

echo "Creating HostedCluster..."
KUBECONFIG="${MGMT_KUBECONFIG}" /usr/bin/hypershift create cluster aws \
  --name "${CLUSTER_NAME}" \
  --infra-id "${INFRA_ID}" \
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
  --instance-type "m5.xlarge" \
  --base-domain "${DOMAIN}" \
  --region "${HYPERSHIFT_AWS_REGION}" \
  --control-plane-availability-policy "SingleReplica" \
  --infra-availability-policy "SingleReplica" \
  --pull-secret /tmp/pull-secret.json \
  --aws-creds "${AWS_GUEST_INFRA_CREDENTIALS_FILE}" \
  --release-image "${RELEASE_IMAGE}" \
  --node-selector "hypershift.openshift.io/control-plane=true" \
  --olm-catalog-placement "management" \
  --additional-tags "expirationDate=${EXPIRATION_DATE}" \
  --annotations "prow.k8s.io/job=${JOB_NAME}" \
  --annotations "cluster-profile=${CLUSTER_PROFILE_NAME}" \
  --annotations "prow.k8s.io/build-id=${BUILD_ID}" \
  --annotations "resource-request-override.hypershift.openshift.io/kube-apiserver.kube-apiserver=memory=3Gi,cpu=2000m" \
  --annotations "hypershift.openshift.io/cleanup-cloud-resources=false" \
  ${CPO_ARGS} \
  --additional-tags "prow.k8s.io/job=${JOB_NAME}" \
  --additional-tags "prow.k8s.io/build-id=${BUILD_ID}"

# Save cluster info for cleanup
echo "CLUSTER_NAME=${CLUSTER_NAME}" > "${SHARED_DIR}/hosted_cluster.txt"
echo "INFRA_ID=${INFRA_ID}" >> "${SHARED_DIR}/hosted_cluster.txt"

# Wait for cluster to become available
echo "Waiting for HostedCluster to become available..."
KUBECONFIG="${MGMT_KUBECONFIG}" oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME} || {
  echo "ERROR: Cluster did not become available"
  KUBECONFIG="${MGMT_KUBECONFIG}" oc get hostedcluster ${CLUSTER_NAME} --namespace=clusters -o yaml > "${ARTIFACT_DIR}/hostedcluster_failed.yaml" 2>/dev/null || true
  exit 1
}
echo "HostedCluster is available"

# Get HC namespace (where control plane pods run)
HC_NAMESPACE="clusters-${CLUSTER_NAME}"
echo "HC namespace: ${HC_NAMESPACE}"

# Get guest cluster kubeconfig
echo "Retrieving guest cluster kubeconfig..."
KUBECONFIG="${MGMT_KUBECONFIG}" /usr/bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} > /tmp/guest_kubeconfig
export GUEST_KUBECONFIG=/tmp/guest_kubeconfig

# Wait for clusterversion to be available in guest
echo "Waiting for guest cluster clusterversion..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc wait --timeout=10m --for='condition=Available=True' clusterversion/version || {
  echo "WARNING: Guest cluster version not available yet, continuing anyway"
}

echo ""
echo "============================================================"
echo "=== Step 1: Record baseline OCM ConfigMap ==="
echo "============================================================"

# Get the OCM ConfigMap from the HC namespace (management cluster)
BASELINE_CONTROLLERS=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap openshift-controller-manager-config \
  -n "${HC_NAMESPACE}" \
  -o go-template='{{index .data "config.yaml"}}' 2>/dev/null | grep -o '"controllers":.*' | head -1 || echo "not-found")

echo "Baseline Controllers field: ${BASELINE_CONTROLLERS}"

echo ""
echo "============================================================"
echo "=== Step 2: Set Image Registry managementState to Removed ==="
echo "============================================================"

echo "Patching imageregistry config to managementState: Removed..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge -p '{"spec":{"managementState":"Removed"}}' || {
  echo "ERROR: Failed to patch imageregistry config — cannot proceed"
  KUBECONFIG="${GUEST_KUBECONFIG}" oc get configs.imageregistry.operator.openshift.io cluster -o yaml 2>/dev/null || true
  exit 1
}

echo "Waiting 30s for HCCO to process the managementState change..."
sleep 30

echo ""
echo "============================================================"
echo "=== Step 3: Verify HCCO modified OCM Controllers field ==="
echo "============================================================"

# Wait for HCCO to set the Controllers field to disable pull-secrets controller
MAX_WAIT=180
INTERVAL=10
ELAPSED=0
HCCO_MODIFIED=false

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  CURRENT_CONTROLLERS=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap openshift-controller-manager-config \
    -n "${HC_NAMESPACE}" \
    -o go-template='{{index .data "config.yaml"}}' 2>/dev/null | grep -o '"controllers":\[[^]]*\]' || echo "")

  if echo "${CURRENT_CONTROLLERS}" | grep -q "serviceaccount-pull-secrets"; then
    echo "HCCO has modified Controllers field after ${ELAPSED}s"
    echo "Controllers: ${CURRENT_CONTROLLERS}"
    HCCO_MODIFIED=true
    break
  fi
  echo "Waiting for HCCO to modify Controllers... (${ELAPSED}s/${MAX_WAIT}s)"
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ "${HCCO_MODIFIED}" == "true" ]]; then
  pass "HCCO modified OCM Controllers to disable pull-secrets controller"
else
  fail "HCCO did not modify OCM Controllers within ${MAX_WAIT}s"
  echo "Current ConfigMap data:"
  KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap openshift-controller-manager-config \
    -n "${HC_NAMESPACE}" -o yaml 2>/dev/null || true
fi

echo ""
echo "============================================================"
echo "=== Step 4: Wait for CPO v2 reconciliation cycles ==="
echo "============================================================"

# CPO v2 reconciles on a regular interval. Wait for multiple cycles
# to ensure the Controllers field is NOT overwritten.
echo "Waiting 120s for 2-3 CPO v2 reconciliation cycles..."
sleep 120

echo ""
echo "============================================================"
echo "=== Step 5: Verify Controllers field is preserved ==="
echo "============================================================"

FINAL_CONTROLLERS=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap openshift-controller-manager-config \
  -n "${HC_NAMESPACE}" \
  -o go-template='{{index .data "config.yaml"}}' 2>/dev/null | grep -o '"controllers":\[[^]]*\]' || echo "")

echo "Final Controllers field: ${FINAL_CONTROLLERS}"

if echo "${FINAL_CONTROLLERS}" | grep -q "serviceaccount-pull-secrets"; then
  pass "CPO v2 preserved HCCO's Controllers modification (pull-secrets controller disabled)"
else
  fail "CPO v2 overwrote HCCO's Controllers modification — pull-secrets controller re-enabled"
  echo "Expected Controllers to contain 'serviceaccount-pull-secrets' disable entry"
  echo "Full OCM ConfigMap:"
  KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap openshift-controller-manager-config \
    -n "${HC_NAMESPACE}" -o yaml 2>/dev/null || true
fi

echo ""
echo "============================================================"
echo "=== Step 6: Verify no pull secrets created for new SA ==="
echo "============================================================"

TEST_NS="verify-ocm-${CLUSTER_NAME:0:10}"
echo "Creating test namespace: ${TEST_NS}"
KUBECONFIG="${GUEST_KUBECONFIG}" oc create namespace "${TEST_NS}" || true

echo "Creating test ServiceAccount..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc create serviceaccount test-sa -n "${TEST_NS}" || true

echo "Waiting 30s for any secret creation..."
sleep 30

# Check for dockercfg secrets associated with the SA
PULL_SECRETS=$(KUBECONFIG="${GUEST_KUBECONFIG}" oc get secrets -n "${TEST_NS}" \
  -o go-template='{{range .items}}{{if eq .type "kubernetes.io/dockercfg"}}{{.metadata.name}} {{end}}{{end}}' 2>/dev/null || echo "")

echo "Pull secrets found: '${PULL_SECRETS}'"

if [[ -z "${PULL_SECRETS}" ]]; then
  pass "No pull secrets created for new ServiceAccount (registry disabled correctly)"
else
  # Check if any are linked to the SA
  SA_PULL_SECRETS=$(KUBECONFIG="${GUEST_KUBECONFIG}" oc get serviceaccount test-sa -n "${TEST_NS}" \
    -o go-template='{{range .imagePullSecrets}}{{.name}} {{end}}' 2>/dev/null || echo "")
  if echo "${SA_PULL_SECRETS}" | grep -q "dockercfg"; then
    fail "Pull secrets were created and associated with ServiceAccount despite registry being Removed"
    echo "SA imagePullSecrets: ${SA_PULL_SECRETS}"
  else
    pass "Pull secrets exist but are not associated with ServiceAccount"
  fi
fi

# Cleanup test namespace
KUBECONFIG="${GUEST_KUBECONFIG}" oc delete namespace "${TEST_NS}" --wait=false 2>/dev/null || true

echo ""
echo "============================================================"
echo "=== Step 7: Verify OCM pod stability (no restart loop) ==="
echo "============================================================"

# Check OCM pod restart count — if CPO v2 was overwriting the ConfigMap,
# OCM would restart on every reconciliation cycle
OCM_RESTARTS=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get pods -n "${HC_NAMESPACE}" \
  -l app=openshift-controller-manager \
  -o go-template='{{range .items}}{{range .status.containerStatuses}}{{.restartCount}}{{end}}{{end}}' 2>/dev/null || echo "unknown")

echo "OCM pod restart count: ${OCM_RESTARTS}"

if [[ "${OCM_RESTARTS}" == "unknown" ]]; then
  skip "Could not determine OCM pod restart count"
elif [[ "${OCM_RESTARTS}" -le 2 ]]; then
  pass "OCM pod is stable (${OCM_RESTARTS} restarts — no reconciliation loop detected)"
else
  fail "OCM pod has ${OCM_RESTARTS} restarts — possible reconciliation loop"
fi

echo ""
echo "============================================================"
echo "=== RESULTS SUMMARY ==="
echo "============================================================"
echo "PASSED: ${PASS_COUNT}"
echo "FAILED: ${FAIL_COUNT}"
echo "SKIPPED: ${SKIP_COUNT}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  echo "RESULT: VERIFICATION FAILED"
  exit 1
else
  echo "RESULT: ALL CHECKS PASSED"
fi
