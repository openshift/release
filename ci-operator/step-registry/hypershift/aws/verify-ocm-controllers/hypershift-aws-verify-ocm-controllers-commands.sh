#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Verify: CPO v2 preserves modifications to OCM Controllers field
# Bug: OCPBUGS-81836 / OCPBUGS-79539
#
# When Image Registry managementState is set to Removed, the
# cluster-openshift-controller-manager-operator disables the pull-secrets
# controller in the OCM ConfigMap. CPO v2 must preserve this modification
# instead of overwriting it on reconciliation.
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

# Management cluster kubeconfig (workload creds for HC creation)
export MGMT_KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

# Cluster naming
HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}
INFRA_ID=${HASH:20:5}
echo "Cluster name: ${CLUSTER_NAME}, Infra ID: ${INFRA_ID}"

# Base domain
DOMAIN="${HYPERSHIFT_BASE_DOMAIN:-ci.hypershift.devcluster.openshift.com}"
echo "Using base domain: ${DOMAIN}"

# Use hypershift-pool-aws-credentials (has Route53 access to ci.hypershift.devcluster.openshift.com)
AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-pool-aws-credentials/credentials"
EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)

# The shared root management cluster runs on arm64; always use --multi-arch
MULTI_ARCH_ARG="--multi-arch"

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
  ${MULTI_ARCH_ARG} \
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

# Compare kubeconfigs
echo ""
echo "=== Debug: comparing kubeconfigs ==="
echo "Workload credentials user:"
KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig oc whoami 2>/dev/null || echo "(whoami failed)"
echo "Admin kubeconfig user:"
KUBECONFIG="${SHARED_DIR}/kubeconfig" oc whoami 2>/dev/null || echo "(whoami failed)"

# Switch to admin kubeconfig for inspecting resources in HC namespace
export MGMT_KUBECONFIG="${SHARED_DIR}/kubeconfig"
echo "Switched to admin kubeconfig for HC namespace access"

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
echo "=== Step 0: Verify CPO image override ==="
echo "============================================================"

# Check the HostedCluster annotation
CPO_ANNOTATION=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get hostedcluster ${CLUSTER_NAME} -n clusters \
  -o jsonpath='{.metadata.annotations.hypershift\.openshift\.io/control-plane-operator-image}' 2>/dev/null || echo "not-set")
echo "CPO annotation on HostedCluster: ${CPO_ANNOTATION}"

# Check the actual CPO pod image
CPO_POD_IMAGE=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get pods -n "${HC_NAMESPACE}" \
  -l app=control-plane-operator \
  -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "unknown")
echo "CPO pod image: ${CPO_POD_IMAGE}"

if [[ -n "${CPO_IMAGE:-}" ]]; then
  if [[ "${CPO_POD_IMAGE}" == *"${CPO_IMAGE}"* ]] || [[ "${CPO_ANNOTATION}" == "${CPO_IMAGE}" ]]; then
    pass "CPO image override is active"
  else
    fail "CPO image override not applied — expected ${CPO_IMAGE}, got pod=${CPO_POD_IMAGE}"
  fi
else
  skip "No CPO image override specified"
fi

echo ""
echo "============================================================"
echo "=== Step 1: Debug — list ConfigMaps and OCM pods ==="
echo "============================================================"

echo "ConfigMaps in ${HC_NAMESPACE} matching 'controller-manager':"
KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmaps -n "${HC_NAMESPACE}" 2>/dev/null | grep -i "controller-manager" || echo "(none found)"

echo ""
echo "OCM pods in ${HC_NAMESPACE}:"
KUBECONFIG="${MGMT_KUBECONFIG}" oc get pods -n "${HC_NAMESPACE}" 2>/dev/null | grep -i "openshift-controller-manager" || echo "(none found)"

echo ""
echo "Dumping OCM ConfigMap (openshift-controller-manager) content:"
KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap openshift-controller-manager -n "${HC_NAMESPACE}" -o yaml 2>/dev/null || echo "ConfigMap 'openshift-controller-manager' not found"

echo ""
echo "Trying 'openshift-controller-manager-config':"
KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap openshift-controller-manager-config -n "${HC_NAMESPACE}" -o yaml 2>/dev/null || echo "ConfigMap 'openshift-controller-manager-config' not found"

# Try to find the right ConfigMap and data key
OCM_CM_NAME=""
OCM_CM_KEY=""
for cm_name in openshift-controller-manager-config openshift-controller-manager config; do
  for key in config.yaml config; do
    CONTENT=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap "${cm_name}" -n "${HC_NAMESPACE}" \
      -o go-template="{{index .data \"${key}\"}}" 2>/dev/null || echo "")
    if [[ -n "${CONTENT}" ]]; then
      echo "Found ConfigMap=${cm_name} key=${key} with content (first 200 chars):"
      echo "${CONTENT}" | head -c 200
      echo ""
      OCM_CM_NAME="${cm_name}"
      OCM_CM_KEY="${key}"
      break 2
    fi
  done
done

if [[ -z "${OCM_CM_NAME}" ]]; then
  echo "ERROR: Could not find OCM ConfigMap — listing all configmaps:"
  KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmaps -n "${HC_NAMESPACE}" 2>/dev/null || true
  fail "Could not find OCM ConfigMap in ${HC_NAMESPACE}"
  # Still continue with remaining tests
fi

echo ""
echo "============================================================"
echo "=== Step 2: Record baseline Controllers field ==="
echo "============================================================"

if [[ -n "${OCM_CM_NAME}" ]]; then
  BASELINE=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap "${OCM_CM_NAME}" -n "${HC_NAMESPACE}" \
    -o go-template="{{index .data \"${OCM_CM_KEY}\"}}" 2>/dev/null || echo "")
  echo "Baseline config content (controllers-related):"
  echo "${BASELINE}" | grep -i "controller" || echo "(no controller references found)"
else
  echo "Skipping — no ConfigMap found"
fi

echo ""
echo "============================================================"
echo "=== Step 3: Set Image Registry managementState to Removed ==="
echo "============================================================"

echo "Patching imageregistry config to managementState: Removed..."
KUBECONFIG="${GUEST_KUBECONFIG}" oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge -p '{"spec":{"managementState":"Removed"}}' || {
  echo "ERROR: Failed to patch imageregistry config — cannot proceed"
  KUBECONFIG="${GUEST_KUBECONFIG}" oc get configs.imageregistry.operator.openshift.io cluster -o yaml 2>/dev/null || true
  exit 1
}

echo "Waiting for cluster-openshift-controller-manager-operator to process the change..."

echo ""
echo "============================================================"
echo "=== Step 4: Wait for Controllers field to be modified ==="
echo "============================================================"

# Wait for the Controllers field to include the pull-secrets disable entry.
# The cluster-openshift-controller-manager-operator watches the imageregistry
# config and modifies the OCM ConfigMap when managementState is Removed.
MAX_WAIT=300
INTERVAL=15
ELAPSED=0
CONTROLLERS_MODIFIED=false

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  if [[ -n "${OCM_CM_NAME}" ]]; then
    CURRENT_CONFIG=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap "${OCM_CM_NAME}" -n "${HC_NAMESPACE}" \
      -o go-template="{{index .data \"${OCM_CM_KEY}\"}}" 2>/dev/null || echo "")

    # Check for the pull-secrets controller disable entry (handles both JSON and YAML formats)
    if echo "${CURRENT_CONFIG}" | grep -q "serviceaccount-pull-secrets"; then
      echo "Controllers field modified after ${ELAPSED}s"
      echo "Matching line:"
      echo "${CURRENT_CONFIG}" | grep "serviceaccount-pull-secrets"
      CONTROLLERS_MODIFIED=true
      break
    fi
  fi
  echo "Waiting for Controllers modification... (${ELAPSED}s/${MAX_WAIT}s)"
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ "${CONTROLLERS_MODIFIED}" == "true" ]]; then
  pass "Controllers field modified to disable pull-secrets controller"
else
  fail "Controllers field not modified within ${MAX_WAIT}s"
  echo "Current ConfigMap content:"
  if [[ -n "${OCM_CM_NAME}" ]]; then
    KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap "${OCM_CM_NAME}" -n "${HC_NAMESPACE}" -o yaml 2>/dev/null || true
  fi
  echo ""
  echo "OCM operator logs (last 30 lines):"
  KUBECONFIG="${MGMT_KUBECONFIG}" oc logs -n "${HC_NAMESPACE}" \
    -l app=openshift-controller-manager-operator --tail=30 2>/dev/null || echo "(no logs available)"
fi

echo ""
echo "============================================================"
echo "=== Step 5: Wait for CPO v2 reconciliation cycles ==="
echo "============================================================"

echo "Waiting 120s for 2-3 CPO v2 reconciliation cycles..."
sleep 120

echo ""
echo "============================================================"
echo "=== Step 6: Verify Controllers field is preserved ==="
echo "============================================================"

if [[ -n "${OCM_CM_NAME}" ]]; then
  FINAL_CONFIG=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap "${OCM_CM_NAME}" -n "${HC_NAMESPACE}" \
    -o go-template="{{index .data \"${OCM_CM_KEY}\"}}" 2>/dev/null || echo "")

  echo "Final config (controllers-related):"
  echo "${FINAL_CONFIG}" | grep -i "controller" || echo "(no controller references)"

  if echo "${FINAL_CONFIG}" | grep -q "serviceaccount-pull-secrets"; then
    pass "CPO v2 preserved Controllers modification (pull-secrets controller disabled)"
  else
    if [[ "${CONTROLLERS_MODIFIED}" == "true" ]]; then
      fail "CPO v2 overwrote Controllers modification — pull-secrets controller re-enabled"
    else
      skip "Controllers field was never modified — cannot verify preservation"
    fi
    echo "Full ConfigMap:"
    KUBECONFIG="${MGMT_KUBECONFIG}" oc get configmap "${OCM_CM_NAME}" -n "${HC_NAMESPACE}" -o yaml 2>/dev/null || true
  fi
else
  skip "No ConfigMap found — cannot verify preservation"
fi

echo ""
echo "============================================================"
echo "=== Step 7: Verify no pull secrets created for new SA ==="
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
echo "=== Step 8: Verify OCM pod stability (no restart loop) ==="
echo "============================================================"

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
